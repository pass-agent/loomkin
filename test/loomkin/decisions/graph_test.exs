defmodule Loomkin.Decisions.GraphTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph

  defp node_attrs(overrides \\ %{}) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  describe "add_node/1" do
    test "creates a decision node with required fields" do
      assert {:ok, node} = Graph.add_node(node_attrs())
      assert node.node_type == :goal
      assert node.title == "Test goal"
      assert node.status == :active
      assert node.change_id != nil
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Graph.add_node(%{})
      assert %{node_type: _, title: _} = errors_on(changeset)
    end

    test "validates confidence range" do
      assert {:error, changeset} = Graph.add_node(node_attrs(%{confidence: 101}))
      assert %{confidence: _} = errors_on(changeset)
    end
  end

  describe "get_node/1 and get_node!/1" do
    test "returns node by id" do
      {:ok, node} = Graph.add_node(node_attrs())
      assert Graph.get_node(node.id).id == node.id
    end

    test "returns nil for missing node" do
      assert Graph.get_node(Ecto.UUID.generate()) == nil
    end

    test "get_node! raises for missing node" do
      assert_raise Ecto.NoResultsError, fn ->
        Graph.get_node!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_node/2" do
    test "updates a node by struct" do
      {:ok, node} = Graph.add_node(node_attrs())
      assert {:ok, updated} = Graph.update_node(node, %{title: "Updated"})
      assert updated.title == "Updated"
    end

    test "updates a node by id" do
      {:ok, node} = Graph.add_node(node_attrs())
      assert {:ok, updated} = Graph.update_node(node.id, %{title: "Updated"})
      assert updated.title == "Updated"
    end

    test "returns error for missing id" do
      assert {:error, :not_found} = Graph.update_node(Ecto.UUID.generate(), %{title: "X"})
    end
  end

  describe "delete_node/1" do
    test "deletes a node" do
      {:ok, node} = Graph.add_node(node_attrs())
      assert {:ok, _} = Graph.delete_node(node.id)
      assert Graph.get_node(node.id) == nil
    end

    test "returns error for missing node" do
      assert {:error, :not_found} = Graph.delete_node(Ecto.UUID.generate())
    end
  end

  describe "list_nodes/1" do
    test "lists all nodes" do
      {:ok, _} = Graph.add_node(node_attrs())
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :action, title: "Action"}))
      assert length(Graph.list_nodes()) == 2
    end

    test "filters by node_type" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :action, title: "Action"}))
      assert length(Graph.list_nodes(node_type: :goal)) == 1
    end

    test "filters by status" do
      {:ok, _} = Graph.add_node(node_attrs(%{status: :active}))
      {:ok, _} = Graph.add_node(node_attrs(%{status: :superseded, title: "Old"}))
      assert length(Graph.list_nodes(status: :active)) == 1
    end
  end

  describe "add_edge/4 and list_edges/1" do
    test "creates an edge between nodes" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "From"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "To"}))

      assert {:ok, edge} = Graph.add_edge(n1.id, n2.id, :leads_to)
      assert edge.from_node_id == n1.id
      assert edge.to_node_id == n2.id
      assert edge.edge_type == :leads_to
    end

    test "creates edge with optional rationale and weight" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "From"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "To"}))

      assert {:ok, edge} =
               Graph.add_edge(n1.id, n2.id, :chosen, rationale: "Best option", weight: 0.9)

      assert edge.rationale == "Best option"
      assert edge.weight == 0.9
    end

    test "filters edges by type" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "C"}))
      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n1.id, n3.id, :chosen)

      assert length(Graph.list_edges(edge_type: :leads_to)) == 1
      assert length(Graph.list_edges(from_node_id: n1.id)) == 2
    end
  end

  describe "active_goals/0" do
    test "returns only active goals" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, status: :active}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, status: :superseded, title: "Old"}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :action, title: "Action"}))

      goals = Graph.active_goals()
      assert length(goals) == 1
      assert hd(goals).node_type == :goal
    end
  end

  describe "recent_decisions/1" do
    test "returns recent decision and option nodes" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :decision, title: "D1"}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :option, title: "O1"}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, title: "G1"}))

      results = Graph.recent_decisions()
      assert length(results) == 2
      types = Enum.map(results, & &1.node_type)
      assert :goal not in types
    end

    test "respects limit" do
      for i <- 1..5 do
        Graph.add_node(node_attrs(%{node_type: :decision, title: "D#{i}"}))
      end

      assert length(Graph.recent_decisions(3)) == 3
    end
  end

  describe "supersede/3" do
    test "creates supersedes edge and marks old node as superseded" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old approach"}))
      {:ok, new} = Graph.add_node(node_attrs(%{title: "New approach"}))

      assert {:ok, edge} = Graph.supersede(old.id, new.id, "Better approach found")
      assert edge.edge_type == :supersedes

      updated_old = Graph.get_node(old.id)
      assert updated_old.status == :superseded
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
