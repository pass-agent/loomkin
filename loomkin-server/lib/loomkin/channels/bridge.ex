defmodule Loomkin.Channels.Bridge do
  @moduledoc """
  Per-binding GenServer that bridges Signal events to a channel adapter
  and routes inbound messages from the channel to the team.

  Each Bridge subscribes to signal topics and forwards relevant
  events to the adapter for delivery. It also handles inbound messages
  and ask_user callback routing.
  """

  use GenServer

  alias Loomkin.Channels.Severity

  # Rate limit: max messages per window
  @rate_limit_max 15
  @rate_limit_window_ms 60_000

  defstruct [
    :binding,
    :adapter,
    pending_questions: %{},
    rate_limiter: {0, nil},
    subscribed_sessions: MapSet.new()
  ]

  # --- Public API ---

  @doc "Start a bridge for the given binding and adapter module."
  def start_link(opts) do
    binding = Keyword.fetch!(opts, :binding)
    adapter = Keyword.fetch!(opts, :adapter)

    GenServer.start_link(__MODULE__, {binding, adapter},
      name: via(binding.channel, binding.channel_id)
    )
  end

  @doc "Route an inbound message from the channel to the team."
  def handle_inbound(channel, channel_id, raw_event) do
    case lookup(channel, channel_id) do
      {:ok, pid} -> GenServer.cast(pid, {:inbound, raw_event})
      :error -> {:error, :no_bridge}
    end
  end

  @doc "Route a callback (e.g. button press) from the channel."
  def handle_callback(channel, channel_id, callback_id, data) do
    case lookup(channel, channel_id) do
      {:ok, pid} -> GenServer.cast(pid, {:callback, callback_id, data})
      :error -> {:error, :no_bridge}
    end
  end

  @doc "Subscribe a running bridge to a session's signal topic."
  def subscribe_session(channel, channel_id, session_id) do
    case lookup(channel, channel_id) do
      {:ok, pid} -> GenServer.cast(pid, {:subscribe_session, session_id})
      :error -> {:error, :no_bridge}
    end
  end

  @doc "Look up a running bridge by channel and channel_id."
  def lookup(channel, channel_id) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:bridge, channel, channel_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({binding, adapter}) do
    _team_id = binding.team_id

    # Subscribe to all relevant signal paths
    Loomkin.Signals.subscribe("team.**")
    Loomkin.Signals.subscribe("agent.**")
    Loomkin.Signals.subscribe("collaboration.**")
    Loomkin.Signals.subscribe("context.**")
    Loomkin.Signals.subscribe("session.**")
    Loomkin.Signals.subscribe("channel.**")

    config = Map.get(binding, :config, %{}) || %{}
    session_id = Map.get(config, "session_id") || Map.get(config, :session_id)

    subscribed_sessions =
      if session_id do
        MapSet.new([session_id])
      else
        MapSet.new()
      end

    {:ok,
     %__MODULE__{
       binding: binding,
       adapter: adapter,
       subscribed_sessions: subscribed_sessions
     }}
  end

  # --- Signal event handlers (severity-gated) ---

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    if signal_for_bridge?(sig, state) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.ask_user.question", data: data} = msg, state) do
    if should_notify?(msg, state) do
      %{question_id: question_id, agent_name: agent_name, question: question, options: options} =
        data

      case rate_limited_send(state, fn ->
             state.adapter.send_question(
               state.binding,
               question_id,
               "[#{agent_name}] #{question}",
               options
             )
           end) do
        {:ok, new_state} ->
          pending = Map.put(new_state.pending_questions, question_id, %{agent_name: agent_name})
          {:noreply, %{new_state | pending_questions: pending}}

        {:rate_limited, new_state} ->
          {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "agent.error", data: data} = msg, state) do
    if should_notify?(msg, state) do
      agent_name = Map.get(data, :agent_name, "unknown")
      error = Map.get(data, :error, "unknown error")
      team_id = state.binding.team_id

      send_if_allowed(state, fn ->
        state.adapter.send_text(
          state.binding,
          "[#{agent_name}] Error: #{error}\nTeam: `#{team_id}`",
          []
        )
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.dissolved"} = msg, state) do
    if should_notify?(msg, state) do
      team_id = state.binding.team_id

      send_if_allowed(state, fn ->
        state.adapter.send_text(
          state.binding,
          "Team `#{team_id}` has been dissolved.",
          []
        )
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.message.new", data: data} = msg, state) do
    if should_notify?(msg, state) do
      role = Map.get(data, :role)
      content = Map.get(data, :content)
      agent_name = Map.get(data, :agent_name, "agent")

      if role == :assistant && content && content != "" do
        team_id = state.binding.team_id
        channel = state.binding.channel

        signal =
          Loomkin.Signals.Channel.Message.new!(%{
            direction: :outbound,
            channel: channel,
            team_id: team_id,
            agent_name: agent_name,
            text: String.slice(content, 0, 200)
          })

        Loomkin.Signals.publish(signal)

        send_if_allowed(state, fn ->
          formatted = state.adapter.format_agent_message(agent_name, content)
          state.adapter.send_text(state.binding, formatted, [])
        end)
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        %Jido.Signal{
          type: "collaboration.peer.message",
          data: %{message: {:collab_event, payload}}
        },
        state
      ) do
    # Classify collab events by their inner type, not the outer signal wrapper
    severity = classify_collab_event(payload)
    levels = notify_levels(state)

    if Severity.notify?(severity, levels) do
      send_if_allowed(state, fn ->
        state.adapter.send_activity(state.binding, payload)
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.permission.request", data: data} = msg, state) do
    if should_notify?(msg, state) do
      team_id = Map.get(data, :team_id, state.binding.team_id)
      tool_name = data.tool_name
      tool_path = data.tool_path
      agent_name = Map.get(data, :agent_name, "unknown")

      request_id =
        Loomkin.Channels.PermissionRegistry.register_request(
          team_id,
          agent_name,
          tool_name,
          tool_path
        )

      text =
        "Permission request `#{request_id}`: #{agent_name} wants to run #{tool_name} on #{tool_path}\n" <>
          "Team: `#{team_id}`\n" <>
          "Reply: /approve #{request_id} once|always|deny"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  # --- Telemetry signal handlers ---

  def handle_info(%Jido.Signal{type: "team.budget.warning", data: data} = msg, state) do
    if should_notify?(msg, state) do
      spent = Map.get(data, :spent, 0)
      limit = Map.get(data, :limit, 0)
      threshold = Map.get(data, :threshold, 0)

      team_id = state.binding.team_id

      text =
        "Budget warning: $#{Float.round(spent / 1, 4)} spent of $#{Float.round(limit / 1, 4)} limit (#{threshold}% threshold)\n" <>
          "Team: `#{team_id}`"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "agent.escalation", data: data} = msg, state) do
    if should_notify?(msg, state) do
      agent_name = Map.get(data, :agent_name, "unknown")
      from_model = Map.get(data, :from_model, "?")
      to_model = Map.get(data, :to_model, "?")

      text = "[#{agent_name}] Escalated: #{from_model} -> #{to_model}"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.llm.stop", data: data} = msg, state) do
    if should_notify?(msg, state) do
      agent_name = Map.get(data, :agent_name, "unknown")
      model = Map.get(data, :model, "?")
      cost = Float.round((Map.get(data, :cost, 0) || 0) / 1, 4)

      tokens =
        (Map.get(data, :input_tokens, 0) || 0) + (Map.get(data, :output_tokens, 0) || 0)

      text = "[#{agent_name}] LLM call: #{model} ($#{cost}, #{tokens} tokens)"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  # --- Session signal handlers ---

  def handle_info(%Jido.Signal{type: "session.permission.request", data: data} = msg, state) do
    if should_notify?(msg, state) do
      session_id = Map.get(data, :session_id, "unknown")
      tool_name = Map.get(data, :tool_name, "unknown")
      tool_path = Map.get(data, :tool_path, "unknown")

      text =
        "Session permission request: tool #{tool_name} on #{tool_path}\n" <>
          "Session: `#{session_id}`\n" <>
          "Approve via the web UI or /perm command."

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.cancelled", data: data} = msg, state) do
    if should_notify?(msg, state) do
      session_id = Map.get(data, :session_id, "unknown")

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Session `#{session_id}` cancelled.", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.llm.error", data: data} = msg, state) do
    if should_notify?(msg, state) do
      error = Map.get(data, :error, "unknown")

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "LLM Error: #{error}", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.status.changed", data: data} = msg, state) do
    if should_notify?(msg, state) do
      session_id = Map.get(data, :session_id, "unknown")
      status = Map.get(data, :status, "unknown")

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Session `#{session_id}` status: #{status}", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.team.available", data: data} = msg, state) do
    if should_notify?(msg, state) do
      team_id = Map.get(data, :team_id, "unknown")

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Team `#{team_id}` is now available.", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "session.child_team.available", data: data} = msg, state) do
    if should_notify?(msg, state) do
      child_team_id = Map.get(data, :child_team_id, "unknown")

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Child team `#{child_team_id}` spawned.", [])
      end)
    else
      {:noreply, state}
    end
  end

  # Catch-all for unhandled signals and other messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Inbound from channel ---

  @impl true
  def handle_cast({:inbound, raw_event}, state) do
    case state.adapter.parse_inbound(raw_event) do
      {:message, text, metadata} ->
        handle_inbound_message(text, metadata, state)

      {:callback, callback_id, data} ->
        handle_inbound_callback(callback_id, data, state)

      :ignore ->
        {:noreply, state}
    end
  end

  def handle_cast({:callback, callback_id, data}, state) do
    handle_inbound_callback(callback_id, data, state)
  end

  def handle_cast({:subscribe_session, session_id}, state) do
    if MapSet.member?(state.subscribed_sessions, session_id) do
      {:noreply, state}
    else
      {:noreply,
       %{state | subscribed_sessions: MapSet.put(state.subscribed_sessions, session_id)}}
    end
  end

  # --- Private ---

  defp handle_inbound_message(text, _metadata, state) do
    team_id = state.binding.team_id
    channel = state.binding.channel

    signal =
      Loomkin.Signals.Channel.Message.new!(%{
        direction: :inbound,
        channel: channel,
        team_id: team_id,
        text: text
      })

    Loomkin.Signals.publish(signal)

    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, "lead"}) do
      [{pid, _}] ->
        Loomkin.Teams.Agent.send_message(pid, text)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  defp handle_inbound_callback(question_id, answer, state) do
    case Map.pop(state.pending_questions, question_id) do
      {nil, _} ->
        {:noreply, state}

      {_meta, remaining} ->
        case Registry.lookup(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}) do
          [{pid, _}] ->
            send(pid, {:ask_user_answer, question_id, answer})

          [] ->
            :ok
        end

        {:noreply, %{state | pending_questions: remaining}}
    end
  end

  defp send_if_allowed(state, send_fn) do
    case rate_limited_send(state, send_fn) do
      {:ok, new_state} -> {:noreply, new_state}
      {:rate_limited, new_state} -> {:noreply, new_state}
    end
  end

  defp rate_limited_send(state, send_fn) do
    {count, window_start} = state.rate_limiter
    now = System.monotonic_time(:millisecond)

    {count, window_start} =
      if window_start == nil || now - window_start > @rate_limit_window_ms do
        {0, now}
      else
        {count, window_start}
      end

    if count >= @rate_limit_max do
      {:rate_limited, %{state | rate_limiter: {count, window_start}}}
    else
      case send_fn.() do
        :ok ->
          {:ok, %{state | rate_limiter: {count + 1, window_start}}}

        {:error, _reason} ->
          {:ok, %{state | rate_limiter: {count + 1, window_start}}}
      end
    end
  end

  @actionable_collab_types [:conflict_detected, :consensus_reached, :task_completed]

  defp classify_collab_event(%{type: type}) when type in @actionable_collab_types, do: :action
  defp classify_collab_event(_), do: :info

  defp should_notify?(event, state) do
    severity = Severity.classify(event)
    levels = notify_levels(state)
    Severity.notify?(severity, levels)
  end

  defp notify_levels(state) do
    config = Map.get(state.binding, :config, %{}) || %{}

    case Map.get(config, "notify") || Map.get(config, :notify) do
      nil -> Severity.default_levels()
      levels when is_list(levels) -> levels
      _ -> Severity.default_levels()
    end
  end

  # Check if signal belongs to this bridge's team or tracked sessions.
  # Session signals must match a subscribed session; team signals must match the binding's team.
  defp signal_for_bridge?(sig, state) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_session_id = get_in(sig.data, [:session_id])

    cond do
      # Session-scoped signals: must match a subscribed session
      signal_session_id != nil ->
        MapSet.member?(state.subscribed_sessions, signal_session_id)

      # Team-scoped signals: must match the binding's team
      signal_team_id != nil ->
        signal_team_id == state.binding.team_id

      # Unscoped signals (system-level): accept
      true ->
        true
    end
  end

  defp via(channel, channel_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:bridge, channel, channel_id}}}
  end
end
