defmodule Loomkin.Teams.Rebalancer do
  @moduledoc """
  Per-team GenServer that detects stuck agents and nudges or escalates.

  Checks periodically for agents in :working status with no recent activity.
  After nudging twice with no progress, escalates to the team lead.
  """

  use GenServer

  alias Loomkin.Signals
  alias Loomkin.Signals.Extensions.Causality
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Context

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
    check_interval_override = Keyword.get(opts, :check_interval)

    Loomkin.Signals.subscribe("agent.status")
    Loomkin.Signals.subscribe("agent.tool.*")
    Loomkin.Signals.subscribe("team.task.*")
    Loomkin.Signals.subscribe("collaboration.peer.message")

    state = %{
      team_id: team_id,
      check_interval_override: check_interval_override,
      working_since: %{},
      last_activity: %{},
      nudge_counts: %{}
    }

    schedule_check(check_interval_override || config_check_interval())

    {:ok, state}
  end

  @impl true
  def handle_info(:check_stuck, state) do
    state = check_for_stuck_agents(state)
    schedule_check(state.check_interval_override || config_check_interval())
    {:noreply, state}
  end

  # Unwrap signal bus delivery tuples
  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    if signal_for_team?(sig, state.team_id) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  # Track agent status transitions
  def handle_info(
        %Jido.Signal{type: "agent.status", data: %{agent_name: name, status: :working}},
        state
      ) do
    now = System.monotonic_time(:millisecond)
    name = to_string(name)

    state =
      state
      |> put_in([:working_since, Access.key(name)], now)
      |> put_in([:last_activity, Access.key(name)], now)

    {:noreply, state}
  end

  def handle_info(
        %Jido.Signal{type: "agent.status", data: %{agent_name: name, status: status}},
        state
      )
      when status in [:idle, :done, :error] do
    name = to_string(name)

    state =
      state
      |> update_in([:working_since], &Map.delete(&1, name))
      |> update_in([:nudge_counts], &Map.delete(&1, name))

    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "agent.status"}, state) do
    {:noreply, state}
  end

  # Track activity signals
  def handle_info(
        %Jido.Signal{type: "agent.tool.complete", data: %{agent_name: agent_name}},
        state
      ) do
    {:noreply, record_activity(state, to_string(agent_name))}
  end

  def handle_info(
        %Jido.Signal{type: "agent.tool.executing", data: %{agent_name: agent_name}},
        state
      ) do
    {:noreply, record_activity(state, to_string(agent_name))}
  end

  def handle_info(%Jido.Signal{type: "team.task.started", data: %{owner: owner}}, state) do
    {:noreply, record_activity(state, to_string(owner), :task_change)}
  end

  def handle_info(%Jido.Signal{type: "team.task.completed", data: %{owner: owner}}, state) do
    {:noreply, record_activity(state, to_string(owner), :task_change)}
  end

  def handle_info(%Jido.Signal{type: "collaboration.peer.message", data: %{from: from}}, state) do
    {:noreply, record_activity(state, to_string(from), :message)}
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp check_for_stuck_agents(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.working_since, state, fn {agent_name, working_since}, acc ->
      if coordination_role?(state.team_id, agent_name) do
        acc
      else
        last_activity = Map.get(acc.last_activity, agent_name, working_since)
        idle_ms = now - last_activity

        if idle_ms > config_stuck_threshold() do
          handle_stuck_agent(acc, agent_name, idle_ms)
        else
          acc
        end
      end
    end)
  end

  defp handle_stuck_agent(state, agent_name, idle_ms) do
    nudge_count = Map.get(state.nudge_counts, agent_name, 0)
    idle_min = div(idle_ms, 60_000)

    max_nudges = config_max_nudges()

    if nudge_count < max_nudges do
      new_count = nudge_count + 1

      nudge_msg =
        "You appear stuck (no activity for #{idle_min}m). " <>
          "Consider breaking down your current task, asking for help, or trying a different approach."

      Comms.send_to(state.team_id, agent_name, {:peer_message, "rebalancer", nudge_msg})

      emit_rebalance_signal(state.team_id, %{
        agent_name: agent_name,
        event: :nudge,
        idle_min: idle_min,
        nudge_count: new_count,
        max_nudges: max_nudges
      })

      put_in(state.nudge_counts[agent_name], new_count)
    else
      current_task = find_agent_current_task(state.team_id, agent_name)

      task_info =
        cond do
          current_task -> current_task[:title] || current_task.id
          true -> describe_agent_work(state.team_id, agent_name)
        end

      Comms.broadcast(state.team_id, {:rebalance_needed, agent_name, task_info})

      emit_rebalance_signal(state.team_id, %{
        agent_name: agent_name,
        event: :escalation,
        idle_min: idle_min,
        task_info: task_info
      })

      put_in(state.nudge_counts[agent_name], 0)
    end
  end

  defp emit_rebalance_signal(team_id, metadata) do
    signal =
      Signals.Team.RebalanceNeeded.new!(%{
        agent_name: to_string(metadata.agent_name),
        task_info: to_string(metadata[:task_info] || ""),
        team_id: team_id
      })

    %{signal | data: Map.merge(signal.data, metadata)}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  defp find_agent_current_task(team_id, agent_name) do
    Context.list_cached_tasks(team_id)
    |> Enum.find(fn t ->
      to_string(t.owner) == to_string(agent_name) and t.status in [:assigned, :in_progress]
    end)
  end

  defp describe_agent_work(team_id, agent_name) do
    case Context.get_agent(team_id, agent_name) do
      {:ok, %{role: role}} -> "#{agent_name} (#{role})"
      _ -> agent_name
    end
  end

  @substantive_signals [:tool_use, :task_change]

  defp record_activity(state, agent_name, signal_type \\ :tool_use) do
    now = System.monotonic_time(:millisecond)

    state = put_in(state, [:last_activity, Access.key(agent_name)], now)

    if signal_type in @substantive_signals do
      update_in(state, [:nudge_counts], &Map.delete(&1, agent_name))
    else
      state
    end
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_stuck, interval)
  end

  defp coordination_role?(team_id, agent_name) do
    case Context.get_agent(team_id, agent_name) do
      {:ok, %{role: role}} -> role in [:weaver, "weaver"]
      _ -> false
    end
  end

  defp signal_for_team?(sig, team_id) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_team_id == nil or signal_team_id == team_id
  end

  # --- Config helpers ---

  defp config_check_interval do
    Loomkin.Config.get(:healing, :rebalancer_check_interval_ms) || @check_interval_ms
  end

  defp config_stuck_threshold do
    Loomkin.Config.get(:healing, :stuck_threshold_ms) || @stuck_threshold_ms
  end

  defp config_max_nudges do
    Loomkin.Config.get(:healing, :max_nudges) || @max_nudges
  end
end
