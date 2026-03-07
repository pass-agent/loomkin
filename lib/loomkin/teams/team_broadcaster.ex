defmodule Loomkin.Teams.TeamBroadcaster do
  @moduledoc """
  GenServer that sits between the Jido Signal Bus and LiveView subscribers,
  batching batchable signals in 50ms windows and instantly forwarding critical signals.

  Each TeamBroadcaster instance serves one session. It subscribes to the global
  bus paths via `Loomkin.Signals.subscribe/1` and forwards processed signals
  to registered subscriber processes via `send/2`.

  ## Signal classification

  - **Critical** (instant forward): permission requests, ask-user, errors, escalations, team dissolved
  - **Batchable** (50ms window): streaming deltas, tool events, status changes, activity events

  Batchable signals are grouped by category (`:streaming`, `:tools`, `:status`, `:activity`)
  and delivered as `{:team_broadcast, %{streaming: [...], tools: [...], ...}}` after
  the flush interval.

  ## Subscriber lifecycle

  Subscribers are monitored via `Process.monitor/1`. Dead subscribers are
  automatically removed. The broadcaster unsubscribes from the signal bus
  in `terminate/2`.
  """

  use GenServer

  alias Loomkin.Signals
  alias Loomkin.Teams.Topics

  @flush_interval_ms 50

  @critical_types MapSet.new([
                    "team.permission.request",
                    "team.ask_user.question",
                    "team.ask_user.answered",
                    "agent.error",
                    "agent.escalation",
                    "team.dissolved"
                  ])

  defstruct team_ids: MapSet.new(),
            flush_ref: nil,
            subscription_ids: [],
            subscribers: %{},
            buffer: %{streaming: [], tools: [], activity: [], status: []}

  # -- Public API --

  @doc "Start a TeamBroadcaster linked to the calling process."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Subscribe a process to receive broadcasted signals. Idempotent.

  The subscriber will receive `{:team_broadcast, batch}` messages.
  """
  def subscribe(broadcaster, pid) do
    GenServer.call(broadcaster, {:subscribe, pid})
  end

  @doc "Add a team_id to the filter set so signals for that team are forwarded."
  def add_team(broadcaster, team_id) do
    GenServer.call(broadcaster, {:add_team, team_id})
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    team_ids =
      opts
      |> Keyword.get(:team_ids, [])
      |> MapSet.new()

    subscription_ids =
      Topics.global_bus_paths()
      |> Enum.reduce([], fn path, acc ->
        case Signals.subscribe(path) do
          {:ok, sub_id} -> [sub_id | acc]
          _error -> acc
        end
      end)

    state = %__MODULE__{
      team_ids: team_ids,
      subscription_ids: subscription_ids
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  def handle_call({:add_team, team_id}, _from, state) do
    {:reply, :ok, %{state | team_ids: MapSet.put(state.team_ids, team_id)}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = signal}, state) do
    team_id = extract_team_id(signal)

    if team_id == nil or MapSet.member?(state.team_ids, team_id) do
      if critical?(signal) do
        broadcast_immediate(state.subscribers, signal)
        {:noreply, state}
      else
        category = classify_category(signal)
        buffer = Map.update!(state.buffer, category, &[signal | &1])
        state = %{state | buffer: buffer}
        state = ensure_flush_timer(state)
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    batch_size =
      Enum.reduce(state.buffer, 0, fn {_cat, signals}, acc -> acc + length(signals) end)

    :telemetry.execute(
      [:loomkin, :team_broadcaster, :flush],
      %{batch_size: batch_size, queue_depth: map_size(state.subscribers)},
      %{team_ids: MapSet.to_list(state.team_ids)}
    )

    # Reverse buffered signals to preserve insertion order
    buffer =
      Map.new(state.buffer, fn {category, signals} -> {category, Enum.reverse(signals)} end)

    broadcast_batch(state.subscribers, buffer)

    {:noreply,
     %{state | buffer: %{streaming: [], tools: [], activity: [], status: []}, flush_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)

    Enum.each(state.subscription_ids, fn sub_id ->
      Signals.unsubscribe(sub_id)
    end)

    :ok
  end

  # -- Private helpers --

  defp extract_team_id(%Jido.Signal{} = signal) do
    get_in(signal.data, [:team_id]) ||
      get_in(signal, [Access.key(:extensions, %{}), "loomkin", "team_id"])
  end

  defp critical?(%Jido.Signal{type: type}) do
    MapSet.member?(@critical_types, type)
  end

  defp classify_category(%Jido.Signal{type: type}) do
    cond do
      String.starts_with?(type, "agent.stream") -> :streaming
      String.starts_with?(type, "agent.tool") -> :tools
      type in ~w(agent.status agent.role.changed agent.queue.updated agent.usage) -> :status
      true -> :activity
    end
  end

  defp ensure_flush_timer(%{flush_ref: nil} = state) do
    ref = Process.send_after(self(), :flush, @flush_interval_ms)
    %{state | flush_ref: ref}
  end

  defp ensure_flush_timer(state), do: state

  defp broadcast_immediate(subscribers, signal) do
    msg = {:team_broadcast, %{critical: [signal]}}
    Enum.each(subscribers, fn {pid, _ref} -> send(pid, msg) end)
  end

  defp broadcast_batch(subscribers, buffer) do
    msg = {:team_broadcast, buffer}
    Enum.each(subscribers, fn {pid, _ref} -> send(pid, msg) end)
  end
end
