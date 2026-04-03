defmodule Loomkin.Decisions.GraphPivotTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph

  defp node_attrs(overrides) do
    Map.merge(
      %{node_type: :decision, title: "Original approach", status: :active},
      overrides
    )
  end

  describe "create_pivot_chain/4" do
    test "creates observation, revisit, and decision nodes" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Use REST API"}))

      assert {:ok, result} =
               Graph.create_pivot_chain(
                 old.id,
                 "REST API has rate limits",
                 "Switch to GraphQL"
               )

      assert result.observation.node_type == :observation
      assert result.observation.title == "REST API has rate limits"

      assert result.revisit.node_type == :revisit
      assert result.revisit.title == "Reconsidering: Use REST API"

      assert result.decision.node_type == :decision
      assert result.decision.title == "Switch to GraphQL"
    end

    test "creates correct edge chain" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old"}))

      {:ok, result} = Graph.create_pivot_chain(old.id, "Observation", "New approach")

      # old -> observation
      edges_from_old = Graph.list_edges(from_node_id: old.id)
      target_ids = Enum.map(edges_from_old, & &1.to_node_id)
      assert result.observation.id in target_ids
      assert result.decision.id in target_ids

      # observation -> revisit
      [obs_edge] = Graph.list_edges(from_node_id: result.observation.id)
      assert obs_edge.to_node_id == result.revisit.id
      assert obs_edge.edge_type == :leads_to

      # revisit -> decision
      [rev_edge] = Graph.list_edges(from_node_id: result.revisit.id)
      assert rev_edge.to_node_id == result.decision.id
      assert rev_edge.edge_type == :leads_to
    end

    test "supersedes the old node" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old"}))

      {:ok, _result} = Graph.create_pivot_chain(old.id, "Observation", "New")

      updated_old = Graph.get_node(old.id)
      assert updated_old.status == :superseded

      # Supersedes edge exists
      supersedes_edges =
        Graph.list_edges(from_node_id: old.id, edge_type: :supersedes)

      assert length(supersedes_edges) == 1
    end

    test "propagates metadata from old node" do
      team_id = Ecto.UUID.generate()
      keeper_id = Ecto.UUID.generate()

      {:ok, old} =
        Graph.add_node(
          node_attrs(%{
            title: "Old",
            metadata: %{"team_id" => team_id, "keeper_id" => keeper_id},
            agent_name: "researcher"
          })
        )

      {:ok, result} = Graph.create_pivot_chain(old.id, "Obs", "New")

      for node <- [result.observation, result.revisit, result.decision] do
        assert node.metadata["team_id"] == team_id
        assert node.metadata["keeper_id"] == keeper_id
        assert node.agent_name == "researcher"
      end
    end

    test "merges opts metadata with old node metadata" do
      {:ok, old} =
        Graph.add_node(node_attrs(%{title: "Old", metadata: %{"team_id" => "t1"}}))

      {:ok, result} =
        Graph.create_pivot_chain(old.id, "Obs", "New", metadata: %{"extra" => "data"})

      assert result.decision.metadata["team_id"] == "t1"
      assert result.decision.metadata["extra"] == "data"
    end

    test "accepts confidence option for new decision" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old"}))

      {:ok, result} =
        Graph.create_pivot_chain(old.id, "Obs", "New", confidence: 75)

      assert result.decision.confidence == 75
    end

    test "returns error for non-existent node" do
      assert {:error, :old_node_not_found} =
               Graph.create_pivot_chain(Ecto.UUID.generate(), "Obs", "New")
    end

    test "returns error for non-active node" do
      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old", status: :superseded}))

      assert {:error, :old_node_not_active} =
               Graph.create_pivot_chain(old.id, "Obs", "New")
    end

    test "broadcasts pivot_created event" do
      Loomkin.Signals.subscribe("decision.**")

      {:ok, old} = Graph.add_node(node_attrs(%{title: "Old"}))
      {:ok, result} = Graph.create_pivot_chain(old.id, "Obs", "New")

      # Drain node_added messages (4 nodes: old + observation + revisit + decision)
      for _ <- 1..3 do
        assert_receive {:signal, %Jido.Signal{type: "decision.node.added"}}
      end

      assert_receive {:signal,
                      %Jido.Signal{type: "decision.pivot.created", data: %{result: ^result}}}
    end

    test "is atomic - all or nothing" do
      # Using a non-existent old node ensures rollback
      assert {:error, :old_node_not_found} =
               Graph.create_pivot_chain(Ecto.UUID.generate(), "Obs", "New")

      # No nodes or edges should have been created
      assert Graph.list_nodes() == []
      assert Graph.list_edges() == []
    end
  end
end
