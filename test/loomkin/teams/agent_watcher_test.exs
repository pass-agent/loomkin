defmodule Loomkin.Teams.AgentWatcherTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.AgentWatcher
  alias Loomkin.Signals

  @team_id "watcher-test-team"
  @agent_name "test-agent"

  setup do
    # Subscribe to all agent signals so we can assert on them
    {:ok, sub_id} = Signals.subscribe("agent.**")

    on_exit(fn ->
      Signals.unsubscribe(sub_id)
    end)

    {:ok, watcher} =
      start_supervised(
        {AgentWatcher, name: :"watcher_test_#{System.unique_integer([:positive])}"}
      )

    %{watcher: watcher}
  end

  describe "crash detection" do
    test "publishes crashed signal when monitored process exits abnormally", %{watcher: watcher} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      AgentWatcher.watch(watcher, pid, @team_id, @agent_name)

      # Kill the process abnormally
      Process.exit(pid, :kill)

      assert_receive {:signal, %Jido.Signal{type: "agent.crashed"} = signal}, 1000
      assert signal.data.agent_name == @agent_name
      assert signal.data.team_id == @team_id
      assert signal.data.crash_count == 1
    end
  end

  describe "recovery detection" do
    test "publishes recovered signal when agent re-registers in registry", %{watcher: watcher} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      AgentWatcher.watch(watcher, pid, @team_id, @agent_name)

      # Register a replacement in the AgentRegistry before the process dies
      replacement = spawn(fn -> Process.sleep(:infinity) end)
      Registry.register(Loomkin.Teams.AgentRegistry, {@team_id, @agent_name}, %{})

      # Kill the original process
      Process.exit(pid, :kill)

      # Should get crashed, then recovered
      assert_receive {:signal, %Jido.Signal{type: "agent.crashed"}}, 1000
      assert_receive {:signal, %Jido.Signal{type: "agent.recovered"} = signal}, 3000
      assert signal.data.agent_name == @agent_name
      assert signal.data.team_id == @team_id

      # Cleanup
      Registry.unregister(Loomkin.Teams.AgentRegistry, {@team_id, @agent_name})
      Process.exit(replacement, :normal)
    end
  end
end
