defmodule Loomkin.Channels.Bridge do
  @moduledoc """
  Per-binding GenServer that bridges PubSub events to a channel adapter
  and routes inbound messages from the channel to the team.

  Each Bridge subscribes to team PubSub topics and forwards relevant
  events to the adapter for delivery. It also handles inbound messages
  and ask_user callback routing.
  """

  use GenServer

  require Logger

  alias Loomkin.Channels.Severity

  @pubsub Loomkin.PubSub

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

  @doc "Subscribe a running bridge to a session's PubSub topic."
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
    team_id = binding.team_id

    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}")
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:tasks")
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:context")
    Phoenix.PubSub.subscribe(@pubsub, "telemetry:team:#{team_id}")

    # Subscribe to session topic if configured in binding
    config = Map.get(binding, :config, %{}) || %{}
    session_id = Map.get(config, "session_id") || Map.get(config, :session_id)

    subscribed_sessions =
      if session_id do
        Phoenix.PubSub.subscribe(@pubsub, "session:#{session_id}")
        MapSet.new([session_id])
      else
        MapSet.new()
      end

    Logger.info(
      "[Bridge] Started for #{binding.channel}:#{binding.channel_id} -> team:#{team_id}"
    )

    {:ok,
     %__MODULE__{
       binding: binding,
       adapter: adapter,
       subscribed_sessions: subscribed_sessions
     }}
  end

  # --- PubSub event handlers (severity-gated) ---

  @impl true
  def handle_info({:ask_user_question, _payload} = msg, state) do
    if should_notify?(msg, state) do
      %{question_id: question_id, agent_name: agent_name, question: question, options: options} =
        elem(msg, 1)

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
          Logger.warning("[Bridge] Rate limited, dropping ask_user for #{question_id}")
          {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:agent_error, payload} = msg, state) do
    if should_notify?(msg, state) do
      agent_name = Map.get(payload, :agent_name, "unknown")
      error = Map.get(payload, :error, "unknown error")
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

  def handle_info(:team_dissolved = msg, state) do
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

  def handle_info({:new_message, payload} = msg, state) do
    if should_notify?(msg, state) do
      role = Map.get(payload, :role)
      content = Map.get(payload, :content)
      agent_name = Map.get(payload, :agent_name, "agent")

      if role == :assistant && content && content != "" do
        team_id = state.binding.team_id
        channel = state.binding.channel

        Phoenix.PubSub.broadcast(
          @pubsub,
          "team:#{team_id}",
          {:channel_message,
           %{
             direction: :outbound,
             channel: channel,
             agent_name: agent_name,
             text: String.slice(content, 0, 200)
           }}
        )

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

  def handle_info({:collab_event, _payload} = msg, state) do
    if should_notify?(msg, state) do
      payload = elem(msg, 1)

      send_if_allowed(state, fn ->
        state.adapter.send_activity(state.binding, payload)
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:permission_request, team_id, tool_name, tool_path, {:agent, _tid, agent_name}} = msg,
        state
      ) do
    if should_notify?(msg, state) do
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

  # --- Telemetry event handlers ---

  def handle_info({:team_budget_warning, payload} = msg, state) do
    if should_notify?(msg, state) do
      spent = Map.get(payload, :spent, 0)
      limit = Map.get(payload, :limit, 0)
      threshold = Map.get(payload, :threshold, 0)

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

  def handle_info({:team_escalation, payload} = msg, state) do
    if should_notify?(msg, state) do
      agent_name = Map.get(payload, :agent_name, "unknown")
      from_model = Map.get(payload, :from_model, "?")
      to_model = Map.get(payload, :to_model, "?")

      text = "[#{agent_name}] Escalated: #{from_model} -> #{to_model}"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info({:team_llm_stop, _payload} = msg, state) do
    if should_notify?(msg, state) do
      payload = elem(msg, 1)
      agent_name = Map.get(payload, :agent_name, "unknown")
      model = Map.get(payload, :model, "?")
      cost = Float.round((Map.get(payload, :cost, 0) || 0) / 1, 4)

      tokens =
        (Map.get(payload, :input_tokens, 0) || 0) + (Map.get(payload, :output_tokens, 0) || 0)

      text = "[#{agent_name}] LLM call: #{model} ($#{cost}, #{tokens} tokens)"

      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, text, [])
      end)
    else
      {:noreply, state}
    end
  end

  # --- Session event handlers ---

  def handle_info({:permission_request, session_id, tool_name, tool_path, :session} = msg, state) do
    if should_notify?(msg, state) do
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

  def handle_info({:new_message, _session_id, msg} = event, state) do
    if should_notify?(event, state) do
      content = if is_map(msg), do: Map.get(msg, :content, inspect(msg)), else: inspect(msg)
      role = if is_map(msg), do: Map.get(msg, :role), else: nil

      if role == :assistant && content && content != "" do
        send_if_allowed(state, fn ->
          state.adapter.send_text(state.binding, "[session] #{String.slice(content, 0, 500)}", [])
        end)
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_cancelled, session_id} = msg, state) do
    if should_notify?(msg, state) do
      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Session `#{session_id}` cancelled.", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info({:llm_error, _session_id, error} = msg, state) do
    if should_notify?(msg, state) do
      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "LLM Error: #{error}", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_status, _session_id, status} = msg, %{binding: binding} = state) do
    if should_notify?(msg, state) do
      session_id = elem(msg, 1)

      send_if_allowed(state, fn ->
        state.adapter.send_text(binding, "Session `#{session_id}` status: #{status}", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info({:team_available, _session_id, team_id} = msg, state) do
    if should_notify?(msg, state) do
      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Team `#{team_id}` is now available.", [])
      end)
    else
      {:noreply, state}
    end
  end

  def handle_info({:child_team_available, _session_id, child_team_id} = msg, state) do
    if should_notify?(msg, state) do
      send_if_allowed(state, fn ->
        state.adapter.send_text(state.binding, "Child team `#{child_team_id}` spawned.", [])
      end)
    else
      {:noreply, state}
    end
  end

  # Catch-all for unhandled PubSub events
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
      Phoenix.PubSub.subscribe(@pubsub, "session:#{session_id}")
      Logger.info("[Bridge] Subscribed to session:#{session_id}")

      {:noreply,
       %{state | subscribed_sessions: MapSet.put(state.subscribed_sessions, session_id)}}
    end
  end

  # --- Private ---

  defp handle_inbound_message(text, _metadata, state) do
    team_id = state.binding.team_id
    channel = state.binding.channel

    # Broadcast channel activity for the UI activity feed
    Phoenix.PubSub.broadcast(
      @pubsub,
      "team:#{team_id}",
      {:channel_message,
       %{
         direction: :inbound,
         channel: channel,
         text: text
       }}
    )

    # Route to the team lead agent if one exists
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, "lead"}) do
      [{pid, _}] ->
        Loomkin.Teams.Agent.send_message(pid, text)

      [] ->
        Logger.warning("[Bridge] No lead agent found for team #{team_id}, message dropped")
    end

    {:noreply, state}
  end

  defp handle_inbound_callback(question_id, answer, state) do
    case Map.pop(state.pending_questions, question_id) do
      {nil, _} ->
        Logger.warning("[Bridge] Received callback for unknown question #{question_id}")
        {:noreply, state}

      {_meta, remaining} ->
        # Route answer back to the waiting agent via Registry
        case Registry.lookup(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}) do
          [{pid, _}] ->
            send(pid, {:ask_user_answer, question_id, answer})

          [] ->
            Logger.warning("[Bridge] No waiting agent for question #{question_id}")
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

        {:error, reason} ->
          Logger.error("[Bridge] Adapter send failed: #{inspect(reason)}")
          {:ok, %{state | rate_limiter: {count + 1, window_start}}}
      end
    end
  end

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

  defp via(channel, channel_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:bridge, channel, channel_id}}}
  end
end
