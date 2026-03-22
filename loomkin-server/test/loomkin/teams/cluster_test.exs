defmodule Loomkin.Teams.ClusterTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Cluster, Distributed, Migration}

  # ── Cluster ─────────────────────────────────────────────────────────

  describe "Cluster.enabled?/0" do
    test "returns false by default" do
      refute Cluster.enabled?()
    end

    test "returns true when configured" do
      original = Application.get_env(:loomkin, :cluster)
      Application.put_env(:loomkin, :cluster, enabled: true)

      assert Cluster.enabled?()

      # Restore
      if original,
        do: Application.put_env(:loomkin, :cluster, original),
        else: Application.delete_env(:loomkin, :cluster)
    end
  end

  describe "Cluster.connected_nodes/0" do
    test "includes self" do
      nodes = Cluster.connected_nodes()
      assert Node.self() in nodes
    end
  end

  describe "Cluster.local_node/0" do
    test "returns the current node" do
      assert Cluster.local_node() == Node.self()
    end
  end

  describe "Cluster.agent_count_per_node/0" do
    test "returns count for local node when clustering is off" do
      counts = Cluster.agent_count_per_node()
      assert is_map(counts)
      assert Map.has_key?(counts, Node.self())
      assert is_integer(counts[Node.self()])
    end
  end

  describe "Cluster.handle_node_join/1" do
    test "broadcasts node_joined event" do
      Loomkin.Signals.subscribe("system.**")
      :ok = Cluster.handle_node_join(:test@localhost)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "system.cluster.node_joined",
                        data: %{node: :test@localhost}
                      }},
                     500
    end
  end

  describe "Cluster.handle_node_leave/1" do
    test "broadcasts node_left event" do
      Loomkin.Signals.subscribe("system.**")
      :ok = Cluster.handle_node_leave(:test@localhost)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "system.cluster.node_left",
                        data: %{node: :test@localhost}
                      }},
                     500
    end
  end

  # ── Distributed ─────────────────────────────────────────────────────

  describe "Distributed.horde_available?/0" do
    test "returns boolean" do
      result = Distributed.horde_available?()
      assert is_boolean(result)
    end
  end

  describe "Distributed.active_supervisor/0" do
    test "returns local supervisor when clustering is off" do
      assert Distributed.active_supervisor() == Loomkin.Teams.AgentSupervisor
    end
  end

  describe "Distributed.active_registry/0" do
    test "returns local registry when clustering is off" do
      assert Distributed.active_registry() == Loomkin.Teams.AgentRegistry
    end
  end

  describe "Distributed.lookup/1" do
    test "returns empty list for unknown key" do
      assert Distributed.lookup({:nonexistent, "agent"}) == []
    end
  end

  describe "Distributed.child_specs/0" do
    test "returns empty list when clustering is off" do
      assert Distributed.child_specs() == []
    end
  end

  # ── Migration ───────────────────────────────────────────────────────

  describe "Migration.migrate_agent/3" do
    test "returns error when clustering is disabled" do
      assert {:error, :clustering_disabled} =
               Migration.migrate_agent("team-1", "agent-1", :target@localhost)
    end
  end

  describe "Migration.serialize_agent_state/2" do
    test "returns error for nonexistent agent" do
      assert {:error, :agent_not_found} =
               Migration.serialize_agent_state("nonexistent-team", "nonexistent-agent")
    end
  end
end
