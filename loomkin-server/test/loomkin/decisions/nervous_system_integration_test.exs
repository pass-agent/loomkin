defmodule Loomkin.Decisions.NervousSystemIntegrationTest do
  @moduledoc "End-to-end tests validating the full nervous system flow across AutoLogger, Broadcaster, Cascade, and ContextBuilder."

  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{AutoLogger, Broadcaster, Graph, ContextBuilder}
  alias Loomkin.Teams.Comms
  alias Loomkin.Schemas.Session

  # Signal bus used instead of PubSub

  defp create_session do
    %Session{}
    |> Session.changeset(%{model: "test-model", project_path: "/tmp/test"})
    |> Repo.insert!()
  end

  defp setup_team(_context) do
    team_id = Ecto.UUID.generate()
    {:ok, _ref} = Loomkin.Teams.TableRegistry.create_table(team_id)
    {:ok, _} = start_supervised({AutoLogger, team_id: team_id}, id: :auto_logger)
    {:ok, _} = start_supervised({Broadcaster, team_id: team_id}, id: :broadcaster)

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "observation triggers discovery notification to relevant agent" do
    setup [:setup_team]

    test "Agent A's goal gets notified when Agent B logs an observation", %{team_id: team_id} do
      # Agent A owns an active goal
      {:ok, goal} =
        Graph.add_node(%{
          node_type: :goal,
          title: "Implement auth system",
          status: :active,
          agent_name: "agent-a",
          metadata: %{"team_id" => team_id}
        })

      # Agent B logs an action under that goal
      {:ok, action} =
        Graph.add_node(%{
          node_type: :action,
          title: "Research OAuth providers",
          agent_name: "agent-b",
          metadata: %{"team_id" => team_id}
        })

      {:ok, _} = Graph.add_edge(goal.id, action.id, :enables)

      # Subscribe as Agent A to receive notifications
      Comms.subscribe(team_id, "agent-a")

      # Agent B logs an observation linked to the action
      {:ok, obs} =
        Graph.add_node(%{
          node_type: :observation,
          title: "Found security vulnerability in provider X",
          agent_name: "agent-b",
          metadata: %{"team_id" => team_id}
        })

      {:ok, _} = Graph.add_edge(action.id, obs.id, :enables)

      # Re-broadcast so Broadcaster picks it up with edges in place
      signal = Loomkin.Signals.Decision.NodeAdded.new!(%{team_id: team_id})
      Loomkin.Signals.publish(%{signal | data: Map.put(signal.data, :node, obs)})

      # Agent A should receive discovery notification (via Comms.send_to -> peer.message signal)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:discovery_relevant, payload}}
                      }},
                     1000

      assert payload.observation_id == obs.id
      assert payload.observation_title == "Found security vulnerability in provider X"
      assert payload.goal_id == goal.id
      assert payload.goal_title == "Implement auth system"
      assert payload.source_agent == "agent-b"
    end
  end

  describe "context offload creates graph node with keeper_id" do
    setup [:setup_team]

    test "AutoLogger creates observation node when keeper_created event fires", %{
      team_id: team_id
    } do
      keeper_id = Ecto.UUID.generate()

      # Emit a proper context.keeper.created signal (AutoLogger subscribes to this type)
      signal =
        Loomkin.Signals.Context.KeeperCreated.new!(%{
          id: keeper_id,
          topic: "authentication-research",
          source: "agent-b",
          team_id: team_id,
          tokens: 1200
        })

      Loomkin.Signals.publish(signal)

      [{logger_pid, _}] =
        Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})

      Loomkin.Decisions.AutoLogger.flush(logger_pid)

      # AutoLogger should have created an observation node
      nodes = Graph.list_nodes(node_type: :observation)
      assert length(nodes) >= 1

      keeper_node = Enum.find(nodes, fn n -> n.metadata["keeper_id"] == keeper_id end)
      assert keeper_node != nil
      assert keeper_node.title == "Context offloaded: authentication-research"
      assert keeper_node.agent_name == "agent-b"
      assert keeper_node.metadata["auto_logged"] == true
      assert keeper_node.metadata["team_id"] == team_id
    end
  end

  describe "low confidence cascades to dependent nodes" do
    setup [:setup_team]

    test "updating decision confidence propagates upstream_uncertainty and notifies agent", %{
      team_id: team_id
    } do
      # Build chain: goal -requires-> decision -requires-> action
      {:ok, goal} =
        Graph.add_node(%{
          node_type: :goal,
          title: "Ship feature",
          status: :active,
          confidence: 90,
          metadata: %{"team_id" => team_id},
          agent_name: "lead"
        })

      {:ok, decision} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Use GraphQL",
          confidence: 80,
          metadata: %{"team_id" => team_id},
          agent_name: "architect"
        })

      {:ok, action} =
        Graph.add_node(%{
          node_type: :action,
          title: "Build GraphQL resolvers",
          metadata: %{"team_id" => team_id},
          agent_name: "coder"
        })

      {:ok, _} = Graph.add_edge(goal.id, decision.id, :requires)
      {:ok, _} = Graph.add_edge(decision.id, action.id, :requires)

      # Subscribe as the downstream agent to receive confidence warnings
      Comms.subscribe(team_id, "coder")

      # Drop decision confidence below threshold (default 50)
      {:ok, _} = Graph.update_node(decision, %{confidence: 30})

      Process.sleep(50)

      # Action should be marked with upstream_uncertainty
      updated_action = Graph.get_node(action.id)
      assert updated_action.metadata["upstream_uncertainty"] == true

      # Agent "coder" should receive confidence_warning (via Comms.send_to -> peer.message signal)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:confidence_warning, warning}}
                      }}

      assert warning.source_node_id == decision.id
      assert warning.source_title == "Use GraphQL"
      assert warning.source_confidence == 30
      assert warning.affected_node_id == action.id
      assert warning.affected_title == "Build GraphQL resolvers"
    end
  end

  describe "ContextBuilder includes prior attempts from other sessions" do
    test "cross_session: true surfaces abandoned decisions from session A in session B" do
      session_a = create_session()
      session_b = create_session()

      # Log a decision in session A, then abandon it
      {:ok, _} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Try microservices approach",
          description: "Too much operational overhead",
          status: :abandoned,
          session_id: session_a.id
        })

      # Also add an active goal in session B
      {:ok, _} =
        Graph.add_node(%{
          node_type: :goal,
          title: "Redesign architecture",
          status: :active,
          session_id: session_b.id
        })

      # Build context for session B with cross_session: true
      {:ok, result} = ContextBuilder.build(session_b.id, cross_session: true)

      # Should include the abandoned decision from session A
      assert result =~ "Prior Attempts & Lessons"
      assert result =~ "[ABANDONED] Try microservices approach"
      assert result =~ "Too much operational overhead"

      # Should also include the active goal from session B (and A since cross_session)
      assert result =~ "Redesign architecture"
    end
  end

  describe "keeper_id in graph nodes enables two-tier retrieval" do
    test "graph node with keeper_id surfaces keeper reference in context" do
      session = create_session()
      keeper_id = Ecto.UUID.generate()

      # Create a goal with keeper_id (simulating deep context offloaded to keeper)
      {:ok, goal} =
        Graph.add_node(%{
          node_type: :goal,
          title: "Optimize database queries",
          status: :active,
          confidence: 75,
          session_id: session.id,
          metadata: %{"keeper_id" => keeper_id}
        })

      # Create related decision with keeper_id too
      {:ok, _decision} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Use materialized views",
          session_id: session.id,
          metadata: %{"keeper_id" => keeper_id}
        })

      # Build context — should include keeper references
      {:ok, result} = ContextBuilder.build(session.id)

      # The graph gives structured summary mentioning the keeper
      assert result =~ "Optimize database queries"
      assert result =~ "Deep context available in keeper #{keeper_id}"

      # Verify the keeper_id can be extracted from the graph node for retrieval
      retrieved = Graph.get_node(goal.id)
      assert retrieved.metadata["keeper_id"] == keeper_id

      # Verify add_node_with_keeper also works for keeper association
      {:ok, linked} =
        Graph.add_node_with_keeper(
          %{node_type: :observation, title: "Query plan analysis", session_id: session.id},
          keeper_id
        )

      assert linked.metadata["keeper_id"] == keeper_id

      # Walk downstream from goal should find linked nodes with keeper context
      {:ok, _} = Graph.add_edge(goal.id, linked.id, :leads_to)
      downstream = Graph.walk_downstream(goal.id, [:leads_to], max_depth: 1)
      assert length(downstream) >= 1

      {found_node, _depth, _type} =
        Enum.find(downstream, fn {n, _d, _t} -> n.id == linked.id end)

      assert found_node.metadata["keeper_id"] == keeper_id
    end
  end
end
