defmodule Loomkin.Teams.RebalancerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Manager, Rebalancer}

  setup do
    # Disable nervous system so we can start Rebalancer manually
    Application.put_env(:loomkin, :start_nervous_system, false)

    {:ok, team_id} = Manager.create_team(name: "rebalance-test")

    on_exit(fn ->
      Application.put_env(:loomkin, :start_nervous_system, true)
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "init/1" do
    test "starts and subscribes to signals", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "agent status tracking" do
    test "tracks working agents on status events", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.Status.new!(%{
           agent_name: "alice",
           team_id: team_id,
           status: :working
         })}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.working_since, "alice")
      assert Map.has_key?(state.last_activity, "alice")

      GenServer.stop(pid)
    end

    test "clears tracking when agent becomes idle", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.Status.new!(%{
           agent_name: "alice",
           team_id: team_id,
           status: :working
         })}
      )

      Process.sleep(50)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.Status.new!(%{
           agent_name: "alice",
           team_id: team_id,
           status: :idle
         })}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.working_since, "alice")
      refute Map.has_key?(state.nudge_counts, "alice")

      GenServer.stop(pid)
    end
  end

  describe "activity tracking" do
    test "records activity from tool results", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.Status.new!(%{
           agent_name: "alice",
           team_id: team_id,
           status: :working
         })}
      )

      Process.sleep(50)

      old_state = :sys.get_state(pid)
      old_activity = old_state.last_activity["alice"]

      Process.sleep(10)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.ToolComplete.new!(%{
           agent_name: "alice",
           team_id: team_id,
           tool_name: "file_read"
         })}
      )

      Process.sleep(50)

      new_state = :sys.get_state(pid)
      assert new_state.last_activity["alice"] > old_activity

      GenServer.stop(pid)
    end

    test "resets nudge count on activity", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      # Manually set nudge count
      :sys.replace_state(pid, fn state ->
        %{state | nudge_counts: Map.put(state.nudge_counts, "alice", 1)}
      end)

      send(
        pid,
        {:signal,
         Loomkin.Signals.Agent.ToolComplete.new!(%{
           agent_name: "alice",
           team_id: team_id,
           tool_name: "shell"
         })}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.nudge_counts, "alice")

      GenServer.stop(pid)
    end
  end

  describe "stuck detection" do
    test "nudges stuck agent on check", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      # Simulate agent working with old timestamps (6 minutes ago)
      old_time = System.monotonic_time(:millisecond) - 6 * 60_000

      :sys.replace_state(pid, fn state ->
        %{state | working_since: %{"alice" => old_time}, last_activity: %{"alice" => old_time}}
      end)

      # Trigger check
      send(pid, :check_stuck)
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert Map.get(state.nudge_counts, "alice") == 1

      GenServer.stop(pid)
    end

    test "escalates after max nudges", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      # Subscribe to signals to get the escalation
      Loomkin.Signals.subscribe("collaboration.**")

      old_time = System.monotonic_time(:millisecond) - 6 * 60_000

      :sys.replace_state(pid, fn state ->
        %{
          state
          | working_since: %{"alice" => old_time},
            last_activity: %{"alice" => old_time},
            nudge_counts: %{"alice" => 2}
        }
      end)

      # Trigger check — should escalate since nudge_count >= max
      send(pid, :check_stuck)
      Process.sleep(100)

      # Escalation is now broadcast as a signal via Comms.broadcast
      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500

      # Nudge count resets after escalation
      state = :sys.get_state(pid)
      assert Map.get(state.nudge_counts, "alice") == 0

      GenServer.stop(pid)
    end

    test "does not nudge agent with recent activity", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      # Agent working with recent activity
      now = System.monotonic_time(:millisecond)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | working_since: %{"alice" => now - 10 * 60_000},
            last_activity: %{"alice" => now - 1_000}
        }
      end)

      send(pid, :check_stuck)
      Process.sleep(100)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.nudge_counts, "alice")

      GenServer.stop(pid)
    end
  end
end
