defmodule Loomkin.Teams.Rebalancer do
  @moduledoc """
  Per-team GenServer that detects stuck agents and nudges or escalates.

  Checks periodically for agents in :working status with no recent activity.
  After nudging twice with no progress, escalates to the team lead.
  """

  use GenServer

  require Logger

  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Context

  @pubsub Loomkin.PubSub
  @check_interval_ms 60_000
  @stuck_threshold_ms 5 * 60_000
  @max_nudges 2

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:rebalancer, team_id}}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    check_interval = Keyword.get(opts, :check_interval, @check_interval_ms)

    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}")
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:tasks")

    state = %{
      team_id: team_id,
      check_interval: check_interval,
      # %{agent_name => monotonic_ms} — when they started working
      working_since: %{},
      # %{agent_name => monotonic_ms} — last observed activity (tool call, message, etc.)
      last_activity: %{},
      # %{agent_name => count} — number of nudges sent
      nudge_counts: %{}
    }

    schedule_check(check_interval)

    Logger.info("[Rebalancer] Started for team #{team_id}")
    {:ok, state}
  end

  @impl true
  def handle_info(:check_stuck, state) do
    state = check_for_stuck_agents(state)
    schedule_check(state.check_interval)
    {:noreply, state}
  end

  # Track agent status transitions
  def handle_info({:agent_status, name, :working}, state) do
    now = System.monotonic_time(:millisecond)
    name = to_string(name)

    state =
      state
      |> put_in([:working_since, Access.key(name)], now)
      |> put_in([:last_activity, Access.key(name)], now)

    {:noreply, state}
  end

  def handle_info({:agent_status, name, status}, state) when status in [:idle, :done, :error] do
    name = to_string(name)

    state =
      state
      |> update_in([:working_since], &Map.delete(&1, name))
      |> update_in([:nudge_counts], &Map.delete(&1, name))

    {:noreply, state}
  end

  # Track activity signals — tool calls, messages sent, task events
  def handle_info({:tool_complete, agent_name, _payload}, state) do
    {:noreply, record_activity(state, to_string(agent_name))}
  end

  def handle_info({:tool_executing, agent_name, _payload}, state) do
    {:noreply, record_activity(state, to_string(agent_name))}
  end

  def handle_info({:task_started, _task_id, owner}, state) do
    {:noreply, record_activity(state, to_string(owner))}
  end

  def handle_info({:task_completed, _task_id, owner, _result}, state) do
    {:noreply, record_activity(state, to_string(owner))}
  end

  def handle_info({:agent_message, from, _to, _content}, state) do
    {:noreply, record_activity(state, to_string(from))}
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp check_for_stuck_agents(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.working_since, state, fn {agent_name, working_since}, acc ->
      last_activity = Map.get(acc.last_activity, agent_name, working_since)
      idle_ms = now - last_activity

      if idle_ms > @stuck_threshold_ms do
        handle_stuck_agent(acc, agent_name, idle_ms)
      else
        acc
      end
    end)
  end

  defp handle_stuck_agent(state, agent_name, idle_ms) do
    nudge_count = Map.get(state.nudge_counts, agent_name, 0)
    idle_min = div(idle_ms, 60_000)

    if nudge_count < @max_nudges do
      # Send a nudge to the stuck agent
      nudge_msg =
        "You appear stuck (no activity for #{idle_min}m). " <>
          "Consider breaking down your current task, asking for help, or trying a different approach."

      Comms.send_to(state.team_id, agent_name, {:peer_message, "rebalancer", nudge_msg})

      Logger.info(
        "[Rebalancer] Nudged #{agent_name} in team #{state.team_id} (#{idle_min}m idle, nudge #{nudge_count + 1})"
      )

      put_in(state.nudge_counts[agent_name], nudge_count + 1)
    else
      # Escalate to the team lead
      current_task = find_agent_current_task(state.team_id, agent_name)
      task_info = if current_task, do: current_task.id, else: "unknown"

      Comms.broadcast(state.team_id, {:rebalance_needed, agent_name, task_info})

      Logger.warning(
        "[Rebalancer] Escalated #{agent_name} in team #{state.team_id} — stuck #{idle_min}m on task #{task_info}"
      )

      # Reset nudge count so we don't spam escalations
      put_in(state.nudge_counts[agent_name], 0)
    end
  end

  defp find_agent_current_task(team_id, agent_name) do
    Context.list_cached_tasks(team_id)
    |> Enum.find(fn t -> t.owner == agent_name and t.status in [:assigned, :in_progress] end)
  end

  defp record_activity(state, agent_name) do
    now = System.monotonic_time(:millisecond)

    state
    |> put_in([:last_activity, Access.key(agent_name)], now)
    |> update_in([:nudge_counts], &Map.delete(&1, agent_name))
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_stuck, interval)
  end
end
