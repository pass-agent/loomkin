defmodule Loomkin.Teams.CrossTeamTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Manager

  setup do
    {:ok, parent_id} = Manager.create_team(name: "cross-parent")
    {:ok, child_a} = Manager.create_sub_team(parent_id, "lead", name: "cross-child-a")
    {:ok, child_b} = Manager.create_sub_team(parent_id, "lead", name: "cross-child-b")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(child_b)
      Loomkin.Teams.TableRegistry.delete_table(child_a)
      Loomkin.Teams.TableRegistry.delete_table(parent_id)
    end)

    %{parent_id: parent_id, child_a: child_a, child_b: child_b}
  end

  describe "cross-team propagation" do
    test "insight discovery propagates to parent team", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "researcher", type: "insight", content: "Key finding about auth"}
      Comms.broadcast_context(child_a, payload)

      assert_receive {:context_update, "researcher", propagated}
      assert propagated.source_team == child_a
      assert propagated.content == "Key finding about auth"
      assert propagated.type == "insight"
    end

    test "blocker discovery propagates to parent team", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "coder", type: "blocker", content: "Cannot proceed: missing dependency"}
      Comms.broadcast_context(child_a, payload)

      assert_receive {:context_update, "coder", propagated}
      assert propagated.source_team == child_a
      assert propagated.type == "blocker"
    end

    test "discovery type now propagates to parent team", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "researcher", type: "discovery", content: "Found something"}
      Comms.broadcast_context(child_a, payload)

      assert_receive {:context_update, "researcher", propagated}
      assert propagated.source_team == child_a
      assert propagated.type == "discovery"
    end

    test "warning type propagates to parent team", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "coder", type: "warning", content: "Deprecated API usage"}
      Comms.broadcast_context(child_a, payload)

      assert_receive {:context_update, "coder", propagated}
      assert propagated.source_team == child_a
      assert propagated.type == "warning"
    end

    test "progress discovery does NOT propagate to parent team", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "coder", type: "progress", content: "Working on task 3"}
      Comms.broadcast_context(child_a, payload)

      refute_receive {:context_update, "coder", _}, 100
    end

    test "propagation can be disabled with propagate_up: false", %{
      parent_id: parent_id,
      child_a: child_a
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "researcher", type: "insight", content: "Key finding"}
      Comms.broadcast_context(child_a, payload, propagate_up: false)

      refute_receive {:context_update, "researcher", _}, 100
    end

    test "root team discovery does not crash (no parent)", %{parent_id: parent_id} do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:context")

      payload = %{from: "lead", type: "insight", content: "Top-level insight"}
      Comms.broadcast_context(parent_id, payload)

      assert_receive {:context_update, "lead", received}
      assert received.content == "Top-level insight"
      refute Map.has_key?(received, :source_team)
    end

    test "child team still receives its own broadcast", %{child_a: child_a} do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_a}:context")

      payload = %{from: "researcher", type: "insight", content: "Shared finding"}
      Comms.broadcast_context(child_a, payload)

      assert_receive {:context_update, "researcher", received}
      assert received.content == "Shared finding"
    end
  end

  describe "team discovery" do
    test "get_sibling_teams returns sibling IDs", %{child_a: child_a, child_b: child_b} do
      assert {:ok, siblings} = Manager.get_sibling_teams(child_a)
      assert child_b in siblings
      refute child_a in siblings
    end

    test "get_sibling_teams returns :none for root team", %{parent_id: parent_id} do
      assert :none = Manager.get_sibling_teams(parent_id)
    end

    test "get_child_teams returns child IDs", %{
      parent_id: parent_id,
      child_a: child_a,
      child_b: child_b
    } do
      children = Manager.get_child_teams(parent_id)
      assert child_a in children
      assert child_b in children
    end

    test "get_child_teams returns empty list for leaf team", %{child_a: child_a} do
      assert [] = Manager.get_child_teams(child_a)
    end

    test "get_team_name returns team name", %{parent_id: parent_id} do
      assert "cross-parent" = Manager.get_team_name(parent_id)
    end

    test "get_team_name returns nil for unknown team" do
      assert nil == Manager.get_team_name("nonexistent-team")
    end

    test "get_team_meta returns metadata", %{parent_id: parent_id} do
      assert {:ok, meta} = Manager.get_team_meta(parent_id)
      assert meta.name == "cross-parent"
      assert meta.id == parent_id
    end
  end

  describe "cross-team messaging" do
    test "send_cross_team delivers to specific agent in another team", %{
      child_a: _child_a,
      child_b: child_b
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_b}:agent:researcher")

      Comms.send_cross_team(child_b, "researcher", {:hello, "from child_a"})

      assert_receive {:hello, "from child_a"}
    end

    test "broadcast_to_children delivers to all child teams", %{
      parent_id: parent_id,
      child_a: child_a,
      child_b: child_b
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_a}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_b}")

      Comms.broadcast_to_children(parent_id, {:announcement, "from parent"})

      assert_receive {:announcement, "from parent"}
      assert_receive {:announcement, "from parent"}
    end

    test "broadcast_to_siblings delivers to sibling teams", %{
      child_a: child_a,
      child_b: child_b
    } do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_b}")

      Comms.broadcast_to_siblings(child_a, {:sibling_msg, "hello sibling"})

      assert_receive {:sibling_msg, "hello sibling"}
    end

    test "broadcast_to_siblings returns :ok for root team", %{parent_id: parent_id} do
      assert :ok = Comms.broadcast_to_siblings(parent_id, {:msg, "no siblings"})
    end
  end

  describe "cross-team queries" do
    test "ask_cross_team routes question and answer across teams", %{
      child_a: child_a,
      child_b: child_b
    } do
      alias Loomkin.Teams.QueryRouter

      # Subscribe to child_b to receive the question
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_b}")

      # Subscribe to child_a agent to receive the answer
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_a}:agent:alice")

      {:ok, query_id} =
        QueryRouter.ask_cross_team(child_a, child_b, "alice", "What is the DB schema?")

      # child_b should receive the broadcast query with source_team metadata
      assert_receive {:query, ^query_id, "alice", "What is the DB schema?",
                      %{source_team: ^child_a}}

      # Answer the query — should route back to child_a
      :ok = QueryRouter.answer(query_id, "bob", "Users table with name and email columns")

      assert_receive {:query_answer, ^query_id, "bob", "Users table with name and email columns",
                      _enrichments}
    end

    test "ask_cross_team to specific agent", %{child_a: child_a, child_b: child_b} do
      alias Loomkin.Teams.QueryRouter

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_b}:agent:bob")

      {:ok, query_id} =
        QueryRouter.ask_cross_team(child_a, child_b, "alice", "Help?", target: "bob")

      assert_receive {:query, ^query_id, "alice", "Help?", %{source_team: ^child_a}}
    end
  end
end
