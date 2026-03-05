defmodule Loomkin.Decisions.GraphMergeTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph

  defp node_attrs(overrides \\ %{}) do
    Map.merge(%{node_type: :goal, title: "Test node"}, overrides)
  end

  defp build_chain do
    {:ok, root} = Graph.add_node(node_attrs(%{title: "Root"}))
    {:ok, child1} = Graph.add_node(node_attrs(%{title: "Child 1", node_type: :decision}))
    {:ok, child2} = Graph.add_node(node_attrs(%{title: "Child 2", node_type: :action}))
    {:ok, _} = Graph.add_edge(root.id, child1.id, :leads_to)
    {:ok, _} = Graph.add_edge(child1.id, child2.id, :chosen)
    {root, child1, child2}
  end

  describe "merge_subtree/3" do
    test "copies a single node under target" do
      {:ok, source} = Graph.add_node(node_attrs(%{title: "Source"}))
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} = Graph.merge_subtree(source.id, target.id)
      assert result.merged_count == 1
      assert result.root_id != source.id

      copied = Graph.get_node(result.root_id)
      assert copied.title == "Source"
    end

    test "copies a chain of nodes preserving edges" do
      {root, _child1, _child2} = build_chain()
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} = Graph.merge_subtree(root.id, target.id)
      assert result.merged_count == 3
      assert map_size(result.id_mapping) == 3

      # Verify the copied root is linked to target
      edges = Graph.list_edges(from_node_id: target.id)
      assert length(edges) == 1
      assert hd(edges).to_node_id == result.root_id

      # Verify internal edges were recreated
      new_root = Graph.get_node(result.root_id)
      downstream = Graph.walk_downstream(new_root.id, [:leads_to, :chosen], max_depth: 5)
      assert length(downstream) == 2
    end

    test "handles diamond paths without duplicates" do
      {:ok, root} = Graph.add_node(node_attrs(%{title: "Root"}))
      {:ok, left} = Graph.add_node(node_attrs(%{title: "Left", node_type: :decision}))
      {:ok, right} = Graph.add_node(node_attrs(%{title: "Right", node_type: :decision}))
      {:ok, bottom} = Graph.add_node(node_attrs(%{title: "Bottom", node_type: :action}))

      {:ok, _} = Graph.add_edge(root.id, left.id, :leads_to)
      {:ok, _} = Graph.add_edge(root.id, right.id, :leads_to)
      {:ok, _} = Graph.add_edge(left.id, bottom.id, :leads_to)
      {:ok, _} = Graph.add_edge(right.id, bottom.id, :leads_to)

      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} = Graph.merge_subtree(root.id, target.id)
      # Should have exactly 4 unique nodes (no duplicates)
      assert result.merged_count == 4
    end

    test "applies prefix_titles option" do
      {:ok, source} = Graph.add_node(node_attrs(%{title: "Original"}))
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} =
               Graph.merge_subtree(source.id, target.id, prefix_titles: "[Merged] ")

      copied = Graph.get_node(result.root_id)
      assert copied.title == "[Merged] Original"
    end

    test "applies metadata_merge option" do
      {:ok, source} =
        Graph.add_node(node_attrs(%{title: "Source", metadata: %{"existing" => "value"}}))

      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} =
               Graph.merge_subtree(source.id, target.id,
                 metadata_merge: %{"branch" => "speculative"}
               )

      copied = Graph.get_node(result.root_id)
      assert copied.metadata["existing"] == "value"
      assert copied.metadata["branch"] == "speculative"
    end

    test "supersede_source marks original nodes as superseded" do
      {root, child1, child2} = build_chain()
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, _result} =
               Graph.merge_subtree(root.id, target.id, supersede_source: true)

      assert Graph.get_node(root.id).status == :superseded
      assert Graph.get_node(child1.id).status == :superseded
      assert Graph.get_node(child2.id).status == :superseded
    end

    test "uses custom edge_type for link to target" do
      {:ok, source} = Graph.add_node(node_attrs(%{title: "Source"}))
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:ok, result} =
               Graph.merge_subtree(source.id, target.id, edge_type: :supports)

      edges = Graph.list_edges(from_node_id: target.id)
      assert hd(edges).edge_type == :supports
      assert hd(edges).to_node_id == result.root_id
    end

    test "returns error for missing source" do
      {:ok, target} = Graph.add_node(node_attrs(%{title: "Target"}))

      assert {:error, :source_not_found} =
               Graph.merge_subtree(Ecto.UUID.generate(), target.id)
    end

    test "returns error for missing target" do
      {:ok, source} = Graph.add_node(node_attrs(%{title: "Source"}))

      assert {:error, :target_not_found} =
               Graph.merge_subtree(source.id, Ecto.UUID.generate())
    end
  end
end
