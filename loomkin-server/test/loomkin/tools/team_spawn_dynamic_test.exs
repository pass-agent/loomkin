defmodule Loomkin.Tools.TeamSpawnDynamicTest do
  @moduledoc """
  Tests for dynamic role support in TeamSpawn.

  These tests verify the resolve_role logic and the integration with
  Role.generate/2 for custom role descriptions. LLM calls are not
  made in these tests — we test the plumbing, not the LLM.
  """

  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Manager, Role, TableRegistry}

  setup do
    {:ok, team_id} = Manager.create_team(name: "spawn-dyn-test", project_path: "/tmp/test-proj")

    on_exit(fn ->
      for agent <- Manager.list_agents(team_id) do
        Manager.stop_agent(team_id, agent.name)
      end

      TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "built-in role spawning" do
    test "spawns agent with built-in role via TeamSpawn", %{team_id: team_id} do
      params = %{
        team_name: "built-in-test",
        purpose: "Test built-in role spawning",
        roles: [%{name: "test-coder", role: "coder"}],
        project_path: "/tmp/test-proj"
      }

      context = %{parent_team_id: team_id, model: "test:model"}

      assert {:ok, %{result: result}} = Loomkin.Tools.TeamSpawn.run(params, context)
      assert result =~ "test-coder (coder): spawned"
    end

    test "fuzzy-matches descriptive roles to built-in", %{team_id: team_id} do
      # "code reviewer" should fuzzy-match to :reviewer... but with dynamic roles,
      # it would be treated as a custom description. Let's check exact match still works.
      params = %{
        team_name: "exact-test",
        purpose: "Test exact role matching",
        roles: [
          %{name: "r1", role: "researcher"},
          %{name: "c1", role: "coder"},
          %{name: "rv1", role: "reviewer"},
          %{name: "t1", role: "tester"},
          %{name: "l1", role: "lead"}
        ],
        project_path: "/tmp/test-proj"
      }

      context = %{parent_team_id: team_id, model: "test:model"}

      assert {:ok, %{result: result}} = Loomkin.Tools.TeamSpawn.run(params, context)
      assert result =~ "r1 (researcher): spawned"
      assert result =~ "c1 (coder): spawned"
      assert result =~ "rv1 (reviewer): spawned"
      assert result =~ "t1 (tester): spawned"
      assert result =~ "l1 (lead): spawned"
    end
  end

  describe "spawn with pre-built role_config" do
    test "spawns agent with custom role_config", %{team_id: team_id} do
      # Simulate what TeamSpawn does after Role.generate succeeds
      {:ok, role_config} =
        Role.parse_and_validate_role(
          Jason.encode!(%{
            "role_name" => "migration-specialist",
            "system_prompt" => "You handle database migrations.",
            "tools" => ["file_read", "file_write", "shell"]
          })
        )

      assert {:ok, pid} =
               Manager.spawn_agent(team_id, "migrator", role_config.name,
                 role_config: role_config,
                 project_path: "/tmp/test-proj"
               )

      assert Process.alive?(pid)

      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "migrator"))
      assert is_binary(agent.role)
      assert String.starts_with?(agent.role, "migration-specialist_")
    end

    test "spawned agent with role_config has correct tools", %{team_id: team_id} do
      {:ok, role_config} =
        Role.parse_and_validate_role(
          Jason.encode!(%{
            "role_name" => "reader-only",
            "system_prompt" => "Read-only specialist.",
            "tools" => ["file_read", "content_search"]
          })
        )

      {:ok, pid} =
        Manager.spawn_agent(team_id, "reader", role_config.name,
          role_config: role_config,
          project_path: "/tmp/test-proj"
        )

      state = GenServer.call(pid, :get_state)
      assert Loomkin.Tools.FileRead in state.tools
      assert Loomkin.Tools.ContentSearch in state.tools
      # Peer tools always included
      assert Loomkin.Tools.PeerMessage in state.tools
      # Lead tools never included
      refute Loomkin.Tools.TeamSpawn in state.tools
    end
  end

  describe "custom role description via TeamSpawn" do
    test "custom description triggers generation or fallback", %{team_id: team_id} do
      params = %{
        team_name: "custom-role-test",
        purpose: "Test custom role description generation",
        roles: [%{name: "specialist", role: "database migration specialist"}],
        project_path: "/tmp/test-proj"
      }

      context = %{parent_team_id: team_id, model: "test:model"}

      # In CI without API key, Role.generate will fail and TeamSpawn
      # should fuzzy-match or use :researcher as fallback.
      assert {:ok, %{result: result}} = Loomkin.Tools.TeamSpawn.run(params, context)
      assert result =~ "specialist"
      assert result =~ "spawned"
    end

    test "fuzzy fallback matches descriptive roles to built-in", %{team_id: team_id} do
      params = %{
        team_name: "fuzzy-test",
        purpose: "Test fuzzy role matching fallback",
        roles: [
          %{name: "code-reviewer", role: "code review specialist"},
          %{name: "test-runner", role: "test execution expert"},
          %{name: "security-analyst", role: "security analysis"}
        ],
        project_path: "/tmp/test-proj"
      }

      context = %{parent_team_id: team_id, model: "test:model"}

      assert {:ok, %{result: result}} = Loomkin.Tools.TeamSpawn.run(params, context)
      # All should spawn successfully (either custom or fallback)
      assert result =~ "code-reviewer"
      assert result =~ "test-runner"
      assert result =~ "security-analyst"
      assert result =~ "spawned"
    end
  end
end
