defmodule Loomkin.Teams.CrossTeamTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Comms, Manager}

  setup do
    {:ok, parent_id} = Manager.create_team(name: "cross-parent")
    {:ok, child_id} = Manager.create_sub_team(parent_id, "lead", name: "cross-child")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(child_id)
      Loomkin.Teams.TableRegistry.delete_table(parent_id)
    end)

    %{parent_id: parent_id, child_id: child_id}
  end

  describe "cross-team propagation" do
    test "insight discovery propagates to parent team", %{
      parent_id: parent_id,
      child_id: child_id
    } do
      # Subscribe to parent's context topic
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      # Broadcast an insight in the child team
      payload = %{from: "researcher", type: "insight", content: "Key finding about auth"}
      Comms.broadcast_context(child_id, payload)

      # Should receive on parent's context topic with source_team marker
      assert_receive {:context_update, "researcher", propagated}
      assert propagated.source_team == child_id
      assert propagated.content == "Key finding about auth"
      assert propagated.type == "insight"
    end

    test "blocker discovery propagates to parent team", %{
      parent_id: parent_id,
      child_id: child_id
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "coder", type: "blocker", content: "Cannot proceed: missing dependency"}
      Comms.broadcast_context(child_id, payload)

      assert_receive {:context_update, "coder", propagated}
      assert propagated.source_team == child_id
      assert propagated.type == "blocker"
    end

    test "progress discovery does NOT propagate to parent team", %{
      parent_id: parent_id,
      child_id: child_id
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "coder", type: "progress", content: "Working on task 3"}
      Comms.broadcast_context(child_id, payload)

      refute_receive {:context_update, "coder", _}, 100
    end

    test "generic discovery type does NOT propagate", %{parent_id: parent_id, child_id: child_id} do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "researcher", type: "discovery", content: "Found something"}
      Comms.broadcast_context(child_id, payload)

      refute_receive {:context_update, "researcher", _}, 100
    end

    test "propagation can be disabled with propagate_up: false", %{
      parent_id: parent_id,
      child_id: child_id
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "researcher", type: "insight", content: "Key finding"}
      Comms.broadcast_context(child_id, payload, propagate_up: false)

      refute_receive {:context_update, "researcher", _}, 100
    end

    test "root team discovery does not crash (no parent)", %{parent_id: parent_id} do
      # Subscribe to parent's own context topic
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "lead", type: "insight", content: "Top-level insight"}
      # Should not crash even though parent has no parent
      Comms.broadcast_context(parent_id, payload)

      # Should receive on own context topic
      assert_receive {:context_update, "lead", received}
      assert received.content == "Top-level insight"
      # Should NOT have source_team (not propagated)
      refute Map.has_key?(received, :source_team)
    end

    test "child team still receives its own broadcast", %{child_id: child_id} do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_id}:context")

      payload = %{from: "researcher", type: "insight", content: "Shared finding"}
      Comms.broadcast_context(child_id, payload)

      # Child team still gets the original broadcast
      assert_receive {:context_update, "researcher", received}
      assert received.content == "Shared finding"
    end
  end
end
