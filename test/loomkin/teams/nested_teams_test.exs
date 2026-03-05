defmodule Loomkin.Teams.NestedTeamsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Manager, TableRegistry}

  setup do
    {:ok, parent_id} = Manager.create_team(name: "parent-team")

    on_exit(fn ->
      # Clean up all teams (parent + any sub-teams)
      for sub_id <- Manager.list_sub_teams(parent_id) do
        TableRegistry.delete_table(sub_id)
      end

      TableRegistry.delete_table(parent_id)
    end)

    %{parent_id: parent_id}
  end

  describe "create_sub_team/3" do
    test "creates a sub-team under parent", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead-agent", name: "sub-team")
      assert is_binary(sub_id)
      assert String.starts_with?(sub_id, "sub-team-")
    end

    test "stores parent_team_id and depth in metadata", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead-agent", name: "child")
      table = TableRegistry.get_table!(sub_id)
      [{:meta, meta}] = :ets.lookup(table, :meta)

      assert meta.parent_team_id == parent_id
      assert meta.depth == 1
      assert meta.spawning_agent == "lead-agent"
    end

    test "registers sub-team in parent's sub_teams list", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead", name: "child-a")
      assert sub_id in Manager.list_sub_teams(parent_id)
    end

    test "allows multiple sub-teams under same parent", %{parent_id: parent_id} do
      {:ok, sub1} = Manager.create_sub_team(parent_id, "lead", name: "child-1")
      {:ok, sub2} = Manager.create_sub_team(parent_id, "lead", name: "child-2")

      subs = Manager.list_sub_teams(parent_id)
      assert sub1 in subs
      assert sub2 in subs
      assert length(subs) == 2
    end

    test "inherits project_path from parent", %{parent_id: _parent_id} do
      {:ok, parent} = Manager.create_team(name: "proj-parent", project_path: "/tmp/myproj")
      {:ok, sub_id} = Manager.create_sub_team(parent, "lead", name: "proj-child")

      table = TableRegistry.get_table!(sub_id)
      [{:meta, meta}] = :ets.lookup(table, :meta)
      assert meta.project_path == "/tmp/myproj"

      TableRegistry.delete_table(sub_id)
      TableRegistry.delete_table(parent)
    end

    test "enforces max nesting depth", %{parent_id: parent_id} do
      {:ok, sub1} = Manager.create_sub_team(parent_id, "lead", name: "depth-1", max_depth: 2)
      {:ok, sub2} = Manager.create_sub_team(sub1, "lead", name: "depth-2", max_depth: 2)

      assert {:error, :max_depth_exceeded} =
               Manager.create_sub_team(sub2, "lead", name: "depth-3", max_depth: 2)

      TableRegistry.delete_table(sub2)
      TableRegistry.delete_table(sub1)
    end

    test "returns error for nonexistent parent" do
      assert {:error, :parent_not_found} =
               Manager.create_sub_team("nonexistent-team", "lead", name: "orphan")
    end
  end

  describe "list_sub_teams/1" do
    test "returns empty list for team with no sub-teams", %{parent_id: parent_id} do
      assert Manager.list_sub_teams(parent_id) == []
    end

    test "returns empty list for nonexistent team" do
      assert Manager.list_sub_teams("no-such-team") == []
    end
  end

  describe "get_parent_team/1" do
    test "returns parent team id for sub-team", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead", name: "child")
      assert {:ok, ^parent_id} = Manager.get_parent_team(sub_id)
      TableRegistry.delete_table(sub_id)
    end

    test "returns :none for root team", %{parent_id: parent_id} do
      assert :none = Manager.get_parent_team(parent_id)
    end

    test "returns :none for nonexistent team" do
      assert :none = Manager.get_parent_team("nonexistent")
    end
  end

  describe "dissolve_team/1 with sub-teams" do
    test "cascades dissolution to sub-teams", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead", name: "cascade-child")
      {:ok, sub_table} = TableRegistry.get_table(sub_id)
      assert :ets.info(sub_table) != :undefined

      Manager.dissolve_team(parent_id)

      # Sub-team's ETS table should be deleted
      assert {:error, :not_found} = TableRegistry.get_table(sub_id)
    end

    test "cascades dissolution recursively through multiple levels" do
      {:ok, root} = Manager.create_team(name: "root-cascade")
      {:ok, mid} = Manager.create_sub_team(root, "lead", name: "mid-level")
      {:ok, leaf} = Manager.create_sub_team(mid, "lead", name: "leaf-level")

      {:ok, leaf_table} = TableRegistry.get_table(leaf)
      assert :ets.info(leaf_table) != :undefined

      Manager.dissolve_team(root)

      assert {:error, :not_found} = TableRegistry.get_table(leaf)
      assert {:error, :not_found} = TableRegistry.get_table(mid)
      assert {:error, :not_found} = TableRegistry.get_table(root)
    end

    test "notifies parent spawning agent on sub-team dissolution", %{parent_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead-agent", name: "notify-child")

      # Subscribe to the parent team's agent topic to catch the notification
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{parent_id}:agent:lead-agent")

      Manager.dissolve_team(sub_id)

      assert_receive {:sub_team_completed, ^sub_id}
    end
  end

  describe "agent_loop context injection" do
    test "includes parent_team_id equal to team_id when team_id is set" do
      config = %{
        project_path: "/tmp/test",
        session_id: "sess-1",
        agent_name: "lead",
        team_id: "team-abc",
        model: "zai:glm-5"
      }

      context = %{
        project_path: config.project_path,
        session_id: config.session_id,
        agent_name: config.agent_name,
        team_id: config.team_id,
        parent_team_id: config.team_id,
        model: config.model
      }

      assert context.parent_team_id == "team-abc"
      assert context.parent_team_id == context.team_id
      assert context.model == "zai:glm-5"
    end

    test "parent_team_id is nil when team_id is nil" do
      config = %{
        project_path: "/tmp/test",
        session_id: "sess-2",
        agent_name: nil,
        team_id: nil,
        model: "zai:glm-5"
      }

      context = %{
        project_path: config.project_path,
        session_id: config.session_id,
        agent_name: config.agent_name,
        team_id: config.team_id,
        parent_team_id: config.team_id,
        model: config.model
      }

      assert context.parent_team_id == nil
      assert context.team_id == nil
    end
  end
end
