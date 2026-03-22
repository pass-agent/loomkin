defmodule Loomkin.Decisions.DiffTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Diff
  alias Loomkin.Decisions.Graph

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test node"}, overrides)
  end

  defp build_small_graph do
    {:ok, root} = Graph.add_node(node_attrs(%{title: "Root", metadata: %{"team_id" => "t1"}}))

    {:ok, child} =
      Graph.add_node(
        node_attrs(%{title: "Child", node_type: :decision, metadata: %{"team_id" => "t1"}})
      )

    {:ok, _edge} = Graph.add_edge(root.id, child.id, :leads_to, rationale: "because")
    {root, child}
  end

  describe "export_patch/1" do
    test "exports nodes and edges as a patch" do
      {root, child} = build_small_graph()

      assert {:ok, patch} = Diff.export_patch(node_ids: [root.id, child.id])

      assert patch["version"] == "1.0"
      assert length(patch["nodes"]) == 2
      assert length(patch["edges"]) == 1

      edge = hd(patch["edges"])
      node_change_ids = Enum.map(patch["nodes"], & &1["change_id"])
      assert edge["from_change_id"] in node_change_ids
      assert edge["to_change_id"] in node_change_ids
      assert edge["edge_type"] == "leads_to"
      assert edge["rationale"] == "because"
    end

    test "exports with team_id filter" do
      build_small_graph()

      {:ok, _other} =
        Graph.add_node(node_attrs(%{title: "Other team", metadata: %{"team_id" => "t2"}}))

      assert {:ok, patch} = Diff.export_patch(team_id: "t1")
      assert length(patch["nodes"]) == 2
    end

    test "includes author and branch" do
      assert {:ok, patch} = Diff.export_patch(author: "agent-1", branch: "feature/x")
      assert patch["author"] == "agent-1"
      assert patch["branch"] == "feature/x"
    end
  end

  describe "validate_patch/1" do
    test "valid patch passes" do
      patch = %{
        "version" => "1.0",
        "nodes" => [%{"change_id" => "abc"}],
        "edges" => [%{"from_change_id" => "abc", "to_change_id" => "abc"}]
      }

      assert :ok = Diff.validate_patch(patch)
    end

    test "detects dangling edge references" do
      patch = %{
        "version" => "1.0",
        "nodes" => [%{"change_id" => "abc"}],
        "edges" => [%{"from_change_id" => "abc", "to_change_id" => "missing"}]
      }

      assert {:error, {:dangling_edge_references, ["missing"]}} = Diff.validate_patch(patch)
    end

    test "rejects invalid format" do
      assert {:error, :invalid_patch_format} = Diff.validate_patch(%{})
      assert {:error, :invalid_patch_format} = Diff.validate_patch("bad")
    end
  end

  describe "apply_patch/2" do
    test "inserts new nodes and edges" do
      {root, child} = build_small_graph()
      {:ok, patch} = Diff.export_patch(node_ids: [root.id, child.id])

      # Delete originals so patch creates fresh copies
      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionEdge)
      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionNode)

      assert {:ok, result} = Diff.apply_patch(patch)
      assert result.nodes_added == 2
      assert result.nodes_skipped == 0
      assert result.edges_added == 1
      assert result.edges_skipped == 0
    end

    test "skips existing nodes by change_id (idempotent)" do
      {root, child} = build_small_graph()
      {:ok, patch} = Diff.export_patch(node_ids: [root.id, child.id])

      # Apply again without deleting — should skip everything
      assert {:ok, result} = Diff.apply_patch(patch)
      assert result.nodes_added == 0
      assert result.nodes_skipped == 2
      assert result.edges_added == 0
      assert result.edges_skipped == 1
    end

    test "dry_run reports counts without inserting" do
      {root, child} = build_small_graph()
      {:ok, patch} = Diff.export_patch(node_ids: [root.id, child.id])

      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionEdge)
      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionNode)

      assert {:ok, result} = Diff.apply_patch(patch, dry_run: true)
      assert result.nodes_added == 2
      assert result.edges_added == 1

      # Nothing actually inserted
      assert Loomkin.Repo.aggregate(Loomkin.Schemas.DecisionNode, :count) == 0
    end

    test "rejects invalid patch" do
      assert {:error, :invalid_patch_format} = Diff.apply_patch(%{})
    end
  end

  describe "round-trip" do
    test "export then apply on clean DB reproduces graph" do
      {root, child} = build_small_graph()
      {:ok, patch} = Diff.export_patch(node_ids: [root.id, child.id])

      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionEdge)
      Loomkin.Repo.delete_all(Loomkin.Schemas.DecisionNode)

      assert {:ok, _} = Diff.apply_patch(patch)

      nodes = Graph.list_nodes()
      assert length(nodes) == 2

      edges = Graph.list_edges()
      assert length(edges) == 1
      assert hd(edges).edge_type == :leads_to
    end
  end
end
