defmodule LoomkinWeb.DecisionGraphMultiAgentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Loomkin.Decisions.Graph
  alias Loomkin.Repo
  alias Loomkin.Schemas.Session

  defp create_session do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        model: "zai:glm-5",
        project_path: "/tmp/test"
      })
      |> Repo.insert()

    session.id
  end

  describe "agent color mapping" do
    test "component renders without errors" do
      session_id = create_session()

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      assert html =~ "Decision Graph"
    end

    test "shows empty state when no decision nodes exist" do
      session_id = create_session()

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      assert html =~ "No decisions recorded yet"
    end

    test "agent color function is deterministic" do
      # phash2 should always return the same hash for the same input
      index1 = :erlang.phash2("researcher", 8)
      index2 = :erlang.phash2("researcher", 8)
      assert index1 == index2

      # Different agents may or may not share colors, but the mapping is stable
      index_a = :erlang.phash2("agent-a", 8)
      index_b = :erlang.phash2("agent-b", 8)
      assert is_integer(index_a)
      assert is_integer(index_b)
      assert index_a >= 0 and index_a < 8
      assert index_b >= 0 and index_b < 8
    end
  end

  describe "agent filter" do
    test "renders All button in filter bar when agents exist" do
      session_id = create_session()

      {:ok, _node} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :goal,
          title: "Test Goal",
          status: :active,
          agent_name: "researcher"
        })

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      assert html =~ "All"
      assert html =~ "researcher"
    end

    test "renders agent legend when agents are present" do
      session_id = create_session()

      {:ok, _node} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :decision,
          title: "Choose approach",
          status: :active,
          agent_name: "coder"
        })

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      assert html =~ "Agents:"
      assert html =~ "coder"
    end
  end

  describe "conflict detection" do
    test "detects conflicts between agents on superseded nodes" do
      session_id = create_session()

      {:ok, node1} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :decision,
          title: "Use REST",
          status: :superseded,
          agent_name: "agent-alpha"
        })

      {:ok, node2} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :decision,
          title: "Use REST",
          status: :active,
          agent_name: "agent-beta"
        })

      {:ok, _edge} = Graph.add_edge(node2.id, node1.id, :supersedes)

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      # Conflict glow rect should be present (rendered with class="conflict-glow")
      assert html =~ ~s(class="conflict-glow")
    end

    test "no conflict glow when same agent supersedes own node" do
      session_id = create_session()

      {:ok, node1} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :decision,
          title: "Old approach",
          status: :superseded,
          agent_name: "solo-agent"
        })

      {:ok, node2} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :decision,
          title: "New approach",
          status: :active,
          agent_name: "solo-agent"
        })

      {:ok, _edge} = Graph.add_edge(node2.id, node1.id, :supersedes)

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph-no-conflict",
          session_id: session_id
        })

      # Same agent superseding its own node should NOT have the conflict glow rect
      refute html =~ ~s(class="conflict-glow")
    end
  end

  describe "multi-agent node rendering" do
    test "renders agent name label on nodes" do
      session_id = create_session()

      {:ok, _node} =
        Graph.add_node(%{
          session_id: session_id,
          node_type: :action,
          title: "Write tests",
          status: :active,
          agent_name: "tester"
        })

      html =
        render_component(LoomkinWeb.DecisionGraphComponent, %{
          id: "test-graph",
          session_id: session_id
        })

      assert html =~ "tester"
    end
  end
end
