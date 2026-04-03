defmodule Loomkin.Decisions.NarrativeTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Graph, Narrative}
  alias Loomkin.Schemas.Session

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  defp create_session do
    %Session{}
    |> Session.changeset(%{model: "test-model", project_path: "/tmp/test"})
    |> Repo.insert!()
  end

  describe "for_session/1" do
    test "returns nodes in a session ordered by inserted_at" do
      session = create_session()

      {:ok, n1} = Graph.add_node(node_attrs(%{title: "First", session_id: session.id}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Second", session_id: session.id}))
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Other session"}))

      result = Narrative.for_session(session.id)
      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert n1.id in ids
      assert n2.id in ids
    end

    test "returns empty list for session with no nodes" do
      assert Narrative.for_session(Ecto.UUID.generate()) == []
    end

    test "excludes auto-logged nodes by default" do
      session = create_session()

      {:ok, manual} = Graph.add_node(node_attrs(%{title: "Manual", session_id: session.id}))

      {:ok, _auto} =
        Graph.add_node(
          node_attrs(%{
            title: "Auto tool action",
            node_type: :action,
            session_id: session.id,
            metadata: %{"auto_logged" => true}
          })
        )

      result = Narrative.for_session(session.id)
      assert length(result) == 1
      assert hd(result).id == manual.id
    end

    test "includes auto-logged nodes when exclude_auto_logged: false" do
      session = create_session()

      {:ok, _} = Graph.add_node(node_attrs(%{title: "Manual", session_id: session.id}))

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Auto",
            node_type: :action,
            session_id: session.id,
            metadata: %{"auto_logged" => true}
          })
        )

      result = Narrative.for_session(session.id, exclude_auto_logged: false)
      assert length(result) == 2
    end
  end

  describe "for_goal/1" do
    test "collects full tree under a goal" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Root"}))
      {:ok, decision} = Graph.add_node(node_attrs(%{node_type: :decision, title: "D1"}))
      {:ok, action} = Graph.add_node(node_attrs(%{node_type: :action, title: "A1"}))

      {:ok, _} = Graph.add_edge(goal.id, decision.id, :leads_to)
      {:ok, _} = Graph.add_edge(decision.id, action.id, :chosen)

      result = Narrative.for_goal(goal.id)
      ids = Enum.map(result, & &1.id)
      assert goal.id in ids
      assert decision.id in ids
      assert action.id in ids
    end

    test "handles cycles without infinite loop" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n1.id, :leads_to)

      result = Narrative.for_goal(n1.id)
      assert length(result) == 2
    end
  end

  describe "format_timeline/1" do
    test "formats nodes as a readable timeline" do
      {:ok, node} = Graph.add_node(node_attrs(%{title: "My goal", confidence: 80}))
      text = Narrative.format_timeline([node])

      assert text =~ "goal: My goal"
      assert text =~ "confidence: 80%"
    end

    test "shows status for non-active nodes" do
      {:ok, node} = Graph.add_node(node_attrs(%{title: "Old", status: :superseded}))
      text = Narrative.format_timeline([node])
      assert text =~ "[superseded]"
    end

    test "returns empty string for empty list" do
      assert Narrative.format_timeline([]) == ""
    end
  end
end
