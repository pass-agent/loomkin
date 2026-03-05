defmodule Loomkin.Teams.RebalancerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Manager, Rebalancer}

  @pubsub Loomkin.PubSub

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
    test "starts and subscribes to team PubSub", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "agent status tracking" do
    test "tracks working agents on status events", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      # Simulate agent starting to work
      Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", {:agent_status, "alice", :working})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.working_since, "alice")
      assert Map.has_key?(state.last_activity, "alice")

      GenServer.stop(pid)
    end

    test "clears tracking when agent becomes idle", %{team_id: team_id} do
      {:ok, pid} = Rebalancer.start_link(team_id: team_id, check_interval: 100_000)

      Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", {:agent_status, "alice", :working})
      Process.sleep(50)

      Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", {:agent_status, "alice", :idle})
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

      Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", {:agent_status, "alice", :working})
      Process.sleep(50)

      old_state = :sys.get_state(pid)
      old_activity = old_state.last_activity["alice"]

      Process.sleep(10)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "team:#{team_id}",
        {:tool_complete, "alice", %{tool_name: "file_read", result: "ok"}}
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

      Phoenix.PubSub.broadcast(
        @pubsub,
        "team:#{team_id}",
        {:tool_complete, "alice", %{tool_name: "shell", result: "ok"}}
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

      # Subscribe to get the nudge message
      Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:agent:alice")

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

      # Subscribe to get the escalation broadcast
      Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}")

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

      assert_receive {:rebalance_needed, "alice", _task_info}

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
