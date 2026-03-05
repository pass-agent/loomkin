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

      {:ok, _} =
        Graph.add_node(node_attrs(%{node_type: :goal, status: :superseded, title: "Old"}))

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

  describe "list_nodes/1 team_id filter" do
    test "filters nodes by team_id in metadata" do
      team_id = Ecto.UUID.generate()
      other_team_id = Ecto.UUID.generate()

      {:ok, _n1} =
        Graph.add_node(node_attrs(%{title: "Team node", metadata: %{"team_id" => team_id}}))

      {:ok, _n2} =
        Graph.add_node(
          node_attrs(%{title: "Other team", metadata: %{"team_id" => other_team_id}})
        )

      {:ok, _n3} = Graph.add_node(node_attrs(%{title: "No team"}))

      results = Graph.list_nodes(team_id: team_id)
      assert length(results) == 1
      assert hd(results).title == "Team node"
    end

    test "returns empty list when no nodes match team_id" do
      {:ok, _} = Graph.add_node(node_attrs(%{metadata: %{"team_id" => "other"}}))
      assert Graph.list_nodes(team_id: "nonexistent") == []
    end
  end

  describe "list_nodes/1 cross_session filter" do
    test "cross_session: true does not restrict results" do
      {:ok, _n1} = Graph.add_node(node_attrs(%{title: "Node A"}))
      {:ok, _n2} = Graph.add_node(node_attrs(%{title: "Node B"}))

      # cross_session: true is a no-op filter — all nodes still returned
      results = Graph.list_nodes(cross_session: true, node_type: :goal)
      assert length(results) == 2
    end

    test "cross_session: true can combine with other filters" do
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Goal", node_type: :goal}))
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Action", node_type: :action}))

      results = Graph.list_nodes(cross_session: true, node_type: :goal)
      assert length(results) == 1
      assert hd(results).title == "Goal"
    end
  end

  describe "add_node_with_keeper/2" do
    test "stores keeper_id in metadata" do
      keeper_id = Ecto.UUID.generate()
      {:ok, node} = Graph.add_node_with_keeper(node_attrs(%{title: "Kept node"}), keeper_id)
      assert node.metadata["keeper_id"] == keeper_id
    end

    test "preserves existing metadata" do
      keeper_id = Ecto.UUID.generate()

      {:ok, node} =
        Graph.add_node_with_keeper(
          node_attrs(%{title: "Kept", metadata: %{"extra" => "data"}}),
          keeper_id
        )

      assert node.metadata["keeper_id"] == keeper_id
      assert node.metadata["extra"] == "data"
    end
  end

  describe "walk_downstream/3" do
    test "walks a chain of nodes downstream" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "Root"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Child"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "Grandchild"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)

      results = Graph.walk_downstream(n1.id, [:leads_to])
      assert length(results) == 2

      ids = Enum.map(results, fn {node, _depth, _type} -> node.id end)
      assert n2.id in ids
      assert n3.id in ids
    end

    test "respects max_depth" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "C"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)

      results = Graph.walk_downstream(n1.id, [:leads_to], max_depth: 1)
      assert length(results) == 1
      assert elem(hd(results), 0).id == n2.id
    end

    test "returns depth and edge_type in tuples" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "Start"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Next"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :enables)

      [{node, depth, edge_type}] = Graph.walk_downstream(n1.id, [:enables])
      assert node.id == n2.id
      assert depth == 1
      assert edge_type == :enables
    end

    test "filters by edge type" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "Root"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Chosen"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "Blocked"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :chosen)
      {:ok, _} = Graph.add_edge(n1.id, n3.id, :blocks)

      results = Graph.walk_downstream(n1.id, [:chosen])
      assert length(results) == 1
      assert elem(hd(results), 0).id == n2.id
    end
  end

  describe "walk_upstream/3" do
    test "walks a chain of nodes upstream" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "Root"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Child"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "Grandchild"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)

      results = Graph.walk_upstream(n3.id, [:leads_to])
      assert length(results) == 2

      ids = Enum.map(results, fn {node, _depth, _type} -> node.id end)
      assert n2.id in ids
      assert n1.id in ids
    end

    test "respects max_depth upstream" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "C"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)

      results = Graph.walk_upstream(n3.id, [:leads_to], max_depth: 1)
      assert length(results) == 1
      assert elem(hd(results), 0).id == n2.id
    end
  end

  describe "connected_nodes/2" do
    test "finds nodes in both directions" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "Parent"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "Center"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "Child"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)

      results = Graph.connected_nodes(n2.id, [:leads_to])
      ids = Enum.map(results, fn {node, _depth, _type} -> node.id end)

      assert n1.id in ids
      assert n3.id in ids
      assert length(results) == 2
    end

    test "deduplicates nodes connected in both directions" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))

      # Edges in both directions between same pair
      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n1.id, :leads_to)

      results = Graph.connected_nodes(n1.id, [:leads_to])
      assert length(results) == 1
      assert elem(hd(results), 0).id == n2.id
    end
  end

  describe "edge walking — circular references" do
    test "visited set prevents infinite loops" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "C"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n2.id, n3.id, :leads_to)
      {:ok, _} = Graph.add_edge(n3.id, n1.id, :leads_to)

      results = Graph.walk_downstream(n1.id, [:leads_to], max_depth: 10)
      # Should find n2, n3 but not loop infinitely back to n1
      ids = Enum.map(results, fn {node, _depth, _type} -> node.id end)
      assert n2.id in ids
      assert n3.id in ids
      assert length(results) == 2
    end
  end

  describe "list_edges/1 with edge_type list" do
    test "filters edges by a list of edge types" do
      {:ok, n1} = Graph.add_node(node_attrs(%{title: "A"}))
      {:ok, n2} = Graph.add_node(node_attrs(%{title: "B"}))
      {:ok, n3} = Graph.add_node(node_attrs(%{title: "C"}))
      {:ok, n4} = Graph.add_node(node_attrs(%{title: "D"}))

      {:ok, _} = Graph.add_edge(n1.id, n2.id, :leads_to)
      {:ok, _} = Graph.add_edge(n1.id, n3.id, :chosen)
      {:ok, _} = Graph.add_edge(n1.id, n4.id, :blocks)

      results = Graph.list_edges(edge_type: [:leads_to, :chosen])
      assert length(results) == 2

      types = Enum.map(results, & &1.edge_type)
      assert :leads_to in types
      assert :chosen in types
      refute :blocks in types
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
