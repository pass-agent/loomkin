defmodule Loomkin.Decisions.BroadcasterTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Broadcaster, Graph}

  @pubsub Loomkin.PubSub
  @team_id "test-team-broadcaster"

  defp node_attrs(overrides) do
    Map.merge(
      %{node_type: :goal, title: "Test goal", metadata: %{"team_id" => @team_id}},
      overrides
    )
  end

  defp start_broadcaster(_context) do
    start_supervised!({Broadcaster, team_id: @team_id})
    :ok
  end

  describe "add_node broadcasts {:node_added, node}" do
    test "Graph.add_node broadcasts to decision_graph topic" do
      Phoenix.PubSub.subscribe(@pubsub, "decision_graph")

      {:ok, node} = Graph.add_node(node_attrs(%{title: "Broadcast test"}))

      assert_receive {:node_added, ^node}, 500
    end
  end

  describe "Broadcaster processes observation/outcome nodes" do
    setup [:start_broadcaster]

    test "notifies agent when observation links to active goal" do
      # Create graph: goal -enables-> action
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Build API",
            status: :active,
            agent_name: "coder-1"
          })
        )

      {:ok, action} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Implement endpoint"}))

      {:ok, _} = Graph.add_edge(goal.id, action.id, :enables)

      # Subscribe to the agent's topic to capture notifications
      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      # Create observation and link it: action -enables-> obs
      {:ok, obs} =
        Graph.add_node(
          node_attrs(%{
            node_type: :observation,
            title: "New discovery",
            agent_name: "researcher-1"
          })
        )

      {:ok, _} = Graph.add_edge(action.id, obs.id, :enables)

      # Re-broadcast now that edge exists (original broadcast from add_node fires before edge)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs})

      assert_receive {:discovery_relevant, payload}, 1000
      assert payload.observation_id == obs.id
      assert payload.observation_title == "New discovery"
      assert payload.goal_id == goal.id
      assert payload.goal_title == "Build API"
      assert payload.source_agent == "researcher-1"
    end

    test "notifies on outcome nodes too" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Deploy service",
            status: :active,
            agent_name: "coder-1"
          })
        )

      {:ok, action} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Run deploy"}))

      {:ok, _} = Graph.add_edge(goal.id, action.id, :leads_to)

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      {:ok, outcome} =
        Graph.add_node(
          node_attrs(%{
            node_type: :outcome,
            title: "Deploy succeeded",
            agent_name: "deployer-1"
          })
        )

      {:ok, _} = Graph.add_edge(action.id, outcome.id, :leads_to)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, outcome})

      assert_receive {:discovery_relevant, payload}, 1000
      assert payload.observation_id == outcome.id
    end

    test "ignores non-observation/outcome node types" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Some goal",
            status: :active,
            agent_name: "coder-1"
          })
        )

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      {:ok, action} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Some action"}))

      {:ok, _} = Graph.add_edge(goal.id, action.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, action})

      refute_receive {:discovery_relevant, _}, 200
    end

    test "ignores nodes from other teams" do
      other_team = "other-team-123"

      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Goal",
            status: :active,
            agent_name: "coder-1"
          })
        )

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      {:ok, obs} =
        Graph.add_node(%{
          node_type: :observation,
          title: "Other team obs",
          metadata: %{"team_id" => other_team}
        })

      {:ok, _} = Graph.add_edge(goal.id, obs.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs})

      refute_receive {:discovery_relevant, _}, 200
    end

    test "includes keeper_id in payload when available" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Goal",
            status: :active,
            agent_name: "coder-1"
          })
        )

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      keeper_id = Ecto.UUID.generate()

      {:ok, obs} =
        Graph.add_node(
          node_attrs(%{
            node_type: :observation,
            title: "Keeper obs",
            agent_name: "researcher-1",
            metadata: %{"team_id" => @team_id, "keeper_id" => keeper_id}
          })
        )

      {:ok, _} = Graph.add_edge(goal.id, obs.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs})

      assert_receive {:discovery_relevant, payload}, 1000
      assert payload.keeper_id == keeper_id
    end

    test "skips goals without agent_name" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Unowned goal",
            status: :active,
            agent_name: nil
          })
        )

      {:ok, obs} =
        Graph.add_node(node_attrs(%{node_type: :observation, title: "Discovery"}))

      {:ok, _} = Graph.add_edge(goal.id, obs.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs})

      # Should not crash; give it time to process
      Process.sleep(100)
    end

    test "skips superseded goals" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Old goal",
            status: :superseded,
            agent_name: "coder-1"
          })
        )

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      {:ok, obs} =
        Graph.add_node(node_attrs(%{node_type: :observation, title: "Finding"}))

      {:ok, _} = Graph.add_edge(goal.id, obs.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs})

      refute_receive {:discovery_relevant, _}, 200
    end
  end

  describe "debouncing" do
    setup [:start_broadcaster]

    test "debounces repeated notifications for same goal+agent" do
      {:ok, goal} =
        Graph.add_node(
          node_attrs(%{
            node_type: :goal,
            title: "Debounce goal",
            status: :active,
            agent_name: "coder-1"
          })
        )

      Phoenix.PubSub.subscribe(@pubsub, "team:#{@team_id}:agent:coder-1")

      # First observation
      {:ok, obs1} =
        Graph.add_node(node_attrs(%{node_type: :observation, title: "First finding"}))

      {:ok, _} = Graph.add_edge(goal.id, obs1.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs1})

      assert_receive {:discovery_relevant, _}, 1000

      # Second observation immediately after (should be debounced)
      {:ok, obs2} =
        Graph.add_node(node_attrs(%{node_type: :observation, title: "Second finding"}))

      {:ok, _} = Graph.add_edge(goal.id, obs2.id, :enables)
      Phoenix.PubSub.broadcast(@pubsub, "decision_graph", {:node_added, obs2})

      refute_receive {:discovery_relevant, _}, 200
    end
  end
end
