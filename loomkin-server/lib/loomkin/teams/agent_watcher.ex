defmodule Loomkin.Teams.AgentWatcher do
  @moduledoc """
  GenServer that monitors agent processes via Process.monitor and publishes
  crash/recovery/permanently-failed signals when agent processes go down.

  This detects GenServer-level process crashes (when the Agent GenServer itself
  dies and DynamicSupervisor restarts it). Distinct from the Agent's internal
  :DOWN handler which handles loop_task crashes.
  """

  use GenServer

  alias Loomkin.Signals

  @max_recovery_checks 5
  @recovery_check_interval_ms 500

  defstruct agents: %{}, crash_counts: %{}

  # -- Public API --

  @doc "Start an AgentWatcher linked to the calling process."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Monitor an agent process. When the process exits abnormally, a Crashed signal
  is published and recovery checks begin.
  """
  def watch(watcher, pid, team_id, agent_name) do
    GenServer.cast(watcher, {:watch, pid, team_id, agent_name})
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:watch, pid, team_id, agent_name}, state) do
    ref = Process.monitor(pid)

    agent_info = %{
      pid: pid,
      team_id: team_id,
      agent_name: agent_name
    }

    crash_count = Map.get(state.crash_counts, {team_id, agent_name}, 0)

    state = %{
      state
      | agents: Map.put(state.agents, ref, agent_info),
        crash_counts: Map.put(state.crash_counts, {team_id, agent_name}, crash_count)
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown] do
    {_agent_info, agents} = Map.pop(state.agents, ref)
    {:noreply, %{state | agents: agents}}
  end

  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, _}}, state) do
    {_agent_info, agents} = Map.pop(state.agents, ref)
    {:noreply, %{state | agents: agents}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.agents, ref) do
      {nil, _agents} ->
        {:noreply, state}

      {%{team_id: team_id, agent_name: agent_name}, agents} ->
        key = {team_id, agent_name}
        crash_count = (Map.get(state.crash_counts, key, 0) || 0) + 1
        crash_counts = Map.put(state.crash_counts, key, crash_count)

        # Publish Crashed signal
        signal =
          Signals.Agent.Crashed.new!(%{
            agent_name: agent_name,
            team_id: team_id,
            crash_count: crash_count
          })

        Signals.publish(signal)

        # Schedule recovery check
        Process.send_after(
          self(),
          {:check_recovery, team_id, agent_name, crash_count, 1},
          @recovery_check_interval_ms
        )

        {:noreply, %{state | agents: agents, crash_counts: crash_counts}}
    end
  end

  def handle_info({:check_recovery, team_id, agent_name, crash_count, attempt}, state) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, agent_name}) do
      [{new_pid, _value}] ->
        # Agent recovered -- re-monitor the new process
        signal =
          Signals.Agent.Recovered.new!(%{
            agent_name: agent_name,
            team_id: team_id,
            crash_count: crash_count
          })

        Signals.publish(signal)

        ref = Process.monitor(new_pid)

        agent_info = %{
          pid: new_pid,
          team_id: team_id,
          agent_name: agent_name
        }

        state = %{state | agents: Map.put(state.agents, ref, agent_info)}
        {:noreply, state}

      [] ->
        if attempt >= @max_recovery_checks do
          # Permanently failed
          signal =
            Signals.Agent.PermanentlyFailed.new!(%{
              agent_name: agent_name,
              team_id: team_id,
              crash_count: crash_count
            })

          Signals.publish(signal)

          {:noreply, state}
        else
          # Retry
          Process.send_after(
            self(),
            {:check_recovery, team_id, agent_name, crash_count, attempt + 1},
            @recovery_check_interval_ms
          )

          {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
