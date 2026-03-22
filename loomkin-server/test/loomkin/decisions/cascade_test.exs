defmodule Loomkin.Decisions.CascadeTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Cascade, Graph}
  alias Loomkin.Teams.Comms

  @team_id "cascade-test-team"

  setup do
    {:ok, _ref} = Loomkin.Teams.TableRegistry.create_table(@team_id)

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(@team_id)
    end)

    :ok
  end

  describe "check_and_propagate/2" do
    test "propagates when confidence drops below threshold" do
      {source, downstream} = create_chain()

      # Drop source confidence below threshold
      {:ok, _} = Graph.update_node(source, %{confidence: 30})

      # Verify downstream node got marked
      updated = Graph.get_node(downstream.id)
      assert updated.metadata["upstream_uncertainty"] == true
    end

    test "does not propagate when confidence is above threshold" do
      {source, downstream} = create_chain()

      {:ok, result} = Cascade.check_and_propagate(source.id, threshold: 20)
      assert result == :above_threshold

      updated = Graph.get_node(downstream.id)
      refute updated.metadata["upstream_uncertainty"]
    end

    test "does not propagate when confidence is nil" do
      {source, _downstream} = create_chain()

      {:ok, result} = Cascade.check_and_propagate(source.id)
      assert result == :above_threshold
    end

    test "respects custom threshold" do
      {source, downstream} = create_chain()

      # Set confidence to 60 — below 70 threshold but above default 50
      Graph.update_node(source, %{confidence: 60})

      # With default threshold (50), should not propagate
      updated = Graph.get_node(downstream.id)
      refute updated.metadata["upstream_uncertainty"]

      # Now with threshold=70, should propagate
      {:ok, count} = Cascade.check_and_propagate(source.id, threshold: 70)
      assert count == 1

      updated = Graph.get_node(downstream.id)
      assert updated.metadata["upstream_uncertainty"] == true
    end

    test "walks through multi-level chains" do
      # A --requires--> B --blocks--> C
      {:ok, a} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Root decision",
          confidence: 25,
          metadata: %{"team_id" => @team_id},
          agent_name: "lead"
        })

      {:ok, b} =
        Graph.add_node(%{
          node_type: :action,
          title: "Middle action",
          metadata: %{},
          agent_name: "worker1"
        })

      {:ok, c} =
        Graph.add_node(%{
          node_type: :action,
          title: "Leaf action",
          metadata: %{},
          agent_name: "worker2"
        })

      {:ok, _} = Graph.add_edge(a.id, b.id, :requires)
      {:ok, _} = Graph.add_edge(b.id, c.id, :blocks)

      {:ok, count} = Cascade.check_and_propagate(a.id)
      assert count == 2

      assert Graph.get_node(b.id).metadata["upstream_uncertainty"] == true
      assert Graph.get_node(c.id).metadata["upstream_uncertainty"] == true
    end

    test "does not follow non-requires/blocks edges" do
      {:ok, source} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Source",
          confidence: 20,
          metadata: %{"team_id" => @team_id}
        })

      {:ok, downstream} =
        Graph.add_node(%{
          node_type: :action,
          title: "Connected via leads_to",
          metadata: %{}
        })

      # Use :leads_to — should NOT be followed by cascade
      {:ok, _} = Graph.add_edge(source.id, downstream.id, :leads_to)

      {:ok, count} = Cascade.check_and_propagate(source.id)
      assert count == 0

      refute Graph.get_node(downstream.id).metadata["upstream_uncertainty"]
    end

    test "is idempotent — re-running does not duplicate updates" do
      {source, downstream} = create_chain()

      # First run
      Graph.update_node(source, %{confidence: 30})
      updated1 = Graph.get_node(downstream.id)
      assert updated1.metadata["upstream_uncertainty"] == true

      # Second run — should skip since already marked
      {:ok, count} = Cascade.check_and_propagate(source.id)
      assert count == 0
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Cascade.check_and_propagate(Ecto.UUID.generate())
    end
  end

  describe "agent notification" do
    test "notifies owning agent via PubSub" do
      # Subscribe to receive the notification
      Comms.subscribe(@team_id, "worker")

      {:ok, source} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Risky call",
          confidence: 25,
          metadata: %{"team_id" => @team_id, "keeper_id" => "k-123"},
          agent_name: "lead"
        })

      {:ok, downstream} =
        Graph.add_node(%{
          node_type: :action,
          title: "Downstream task",
          metadata: %{},
          agent_name: "worker"
        })

      {:ok, _} = Graph.add_edge(source.id, downstream.id, :requires)

      {:ok, 1} = Cascade.check_and_propagate(source.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:confidence_warning, warning}}
                      }}

      assert warning.source_node_id == source.id
      assert warning.source_title == "Risky call"
      assert warning.source_confidence == 25
      assert warning.affected_node_id == downstream.id
      assert warning.affected_title == "Downstream task"
      assert warning.keeper_id == "k-123"
      assert warning.edge_path == [:requires]
    end

    test "includes keeper_id from source node metadata" do
      Comms.subscribe(@team_id, "alice")

      {:ok, source} =
        Graph.add_node(%{
          node_type: :observation,
          title: "Uncertain data",
          confidence: 10,
          metadata: %{"team_id" => @team_id, "keeper_id" => "keeper-abc"}
        })

      {:ok, downstream} =
        Graph.add_node(%{
          node_type: :action,
          title: "Uses uncertain data",
          metadata: %{},
          agent_name: "alice"
        })

      {:ok, _} = Graph.add_edge(source.id, downstream.id, :requires)
      {:ok, _} = Cascade.check_and_propagate(source.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:confidence_warning, warning}}
                      }}

      assert warning.keeper_id == "keeper-abc"
    end
  end

  describe "Graph.update_node cascade hook" do
    test "automatically triggers cascade when confidence is updated" do
      Comms.subscribe(@team_id, "bob")

      {:ok, source} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Auto-cascade test",
          metadata: %{"team_id" => @team_id},
          confidence: 80
        })

      {:ok, downstream} =
        Graph.add_node(%{
          node_type: :action,
          title: "Depends on decision",
          metadata: %{},
          agent_name: "bob"
        })

      {:ok, _} = Graph.add_edge(source.id, downstream.id, :requires)

      # Update confidence below threshold — should auto-cascade
      {:ok, _} = Graph.update_node(source, %{confidence: 30})

      Process.sleep(20)
      updated = Graph.get_node(downstream.id)
      assert updated.metadata["upstream_uncertainty"] == true

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:confidence_warning, _}}
                      }}
    end

    test "does not trigger cascade when updating non-confidence fields" do
      {:ok, source} =
        Graph.add_node(%{
          node_type: :decision,
          title: "No cascade",
          confidence: 30,
          metadata: %{"team_id" => @team_id}
        })

      {:ok, downstream} =
        Graph.add_node(%{
          node_type: :action,
          title: "Should not be affected",
          metadata: %{}
        })

      {:ok, _} = Graph.add_edge(source.id, downstream.id, :requires)

      # Update title only — should NOT trigger cascade
      {:ok, _} = Graph.update_node(source, %{title: "Renamed"})

      refute Graph.get_node(downstream.id).metadata["upstream_uncertainty"]
    end
  end

  # --- Helpers ---

  defp create_chain do
    {:ok, source} =
      Graph.add_node(%{
        node_type: :decision,
        title: "Source decision",
        confidence: 80,
        metadata: %{"team_id" => @team_id},
        agent_name: "lead"
      })

    {:ok, downstream} =
      Graph.add_node(%{
        node_type: :action,
        title: "Downstream action",
        metadata: %{},
        agent_name: "worker"
      })

    {:ok, _} = Graph.add_edge(source.id, downstream.id, :requires)

    {source, downstream}
  end
end
