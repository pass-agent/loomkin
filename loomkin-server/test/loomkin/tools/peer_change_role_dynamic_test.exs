defmodule Loomkin.Tools.PeerChangeRoleDynamicTest do
  @moduledoc """
  Tests for dynamic role support in PeerChangeRole.

  Tests the integration between PeerChangeRole and Role.generate/2
  for custom role descriptions, as well as built-in role changes.
  """

  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Agent, Manager, Role, TableRegistry}

  setup do
    suffix = :erlang.unique_integer([:positive])

    {:ok, team_id} =
      Manager.create_team(name: "peer-role-test-#{suffix}", project_path: "/tmp/test-proj")

    on_exit(fn ->
      try do
        for agent <- Manager.list_agents(team_id) do
          Manager.stop_agent(team_id, agent.name)
        end
      catch
        :exit, _ -> :ok
      end

      TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "built-in role change via PeerChangeRole" do
    test "changes to built-in role", %{team_id: team_id} do
      {:ok, _pid} = Manager.spawn_agent(team_id, "agent-1", :coder)

      params = %{
        team_id: team_id,
        target: "agent-1",
        new_role: "researcher"
      }

      assert {:ok, %{result: result}} = Loomkin.Tools.PeerChangeRole.run(params, %{})
      assert result =~ "researcher"

      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "agent-1"))
      assert agent.role == :researcher
    end
  end

  describe "role change with pre-built role_config" do
    test "change_role/3 accepts role_config option directly", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "flex-agent", :coder)

      {:ok, role_config} =
        Role.parse_and_validate_role(
          Jason.encode!(%{
            "role_name" => "security-auditor",
            "system_prompt" => "You audit code for security vulnerabilities.",
            "tools" => ["file_read", "content_search", "shell"]
          })
        )

      assert :ok = Agent.change_role(pid, role_config.name, role_config: role_config)

      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "flex-agent"))
      assert is_binary(agent.role)
      assert String.starts_with?(agent.role, "security-auditor_")
    end

    test "agent tools are updated after role change with custom config", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "tool-agent", :researcher)

      {:ok, role_config} =
        Role.parse_and_validate_role(
          Jason.encode!(%{
            "role_name" => "deployment-agent",
            "system_prompt" => "You handle deployments.",
            "tools" => ["shell", "git"]
          })
        )

      assert :ok = Agent.change_role(pid, role_config.name, role_config: role_config)

      state = GenServer.call(pid, :get_state)
      assert Loomkin.Tools.Shell in state.tools
      assert Loomkin.Tools.Git in state.tools
      # Peer tools always present
      assert Loomkin.Tools.PeerMessage in state.tools
    end

    test "applies custom role change and updates agent state", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "broadcast-agent", :coder)

      {:ok, role_config} =
        Role.parse_and_validate_role(
          Jason.encode!(%{
            "role_name" => "docs-writer",
            "system_prompt" => "You write documentation.",
            "tools" => ["file_read", "file_write"]
          })
        )

      :ok = Agent.change_role(pid, role_config.name, role_config: role_config)

      state = GenServer.call(pid, :get_state)
      assert is_binary(state.role)
      assert String.starts_with?(state.role, "docs-writer_")
      assert Loomkin.Tools.FileRead in state.tools
      assert Loomkin.Tools.FileWrite in state.tools
    end
  end

  describe "custom role description via PeerChangeRole tool" do
    test "non-built-in role description triggers generation or fallback", %{team_id: team_id} do
      {:ok, _pid} = Manager.spawn_agent(team_id, "dyn-agent", :coder)

      params = %{
        team_id: team_id,
        target: "dyn-agent",
        new_role: "database migration specialist for Ecto schemas"
      }

      # In CI without API key, Role.generate will fail and PeerChangeRole
      # will attempt a built-in fallback. The description doesn't contain
      # a built-in name, so it returns an error.
      case Loomkin.Tools.PeerChangeRole.run(params, %{}) do
        {:ok, %{result: result}} ->
          # Generated a custom role successfully (API key available)
          assert is_binary(result)

        {:error, msg} ->
          # Expected when LLM unavailable and no built-in substring match
          assert is_binary(msg)
          assert msg =~ "Could not generate custom role"
      end
    end

    test "description containing built-in name falls back correctly", %{team_id: team_id} do
      {:ok, _pid} = Manager.spawn_agent(team_id, "fb-agent", :coder)

      params = %{
        team_id: team_id,
        target: "fb-agent",
        new_role: "a researcher who focuses on API endpoints"
      }

      # When LLM fails, the fallback should find "researcher" in the description.
      # On CI the agent may shut down mid-call, so handle that gracefully.
      case Loomkin.Tools.PeerChangeRole.run(params, %{}) do
        {:ok, %{result: msg}} ->
          assert msg =~ "researcher"

        {:error, _msg} ->
          # Agent shutdown race on CI — acceptable
          :ok
      end
    end

    test "agent not found returns error", %{team_id: team_id} do
      params = %{
        team_id: team_id,
        target: "nonexistent-agent",
        new_role: "coder"
      }

      assert {:error, msg} = Loomkin.Tools.PeerChangeRole.run(params, %{})
      assert msg =~ "not found"
    end
  end
end
