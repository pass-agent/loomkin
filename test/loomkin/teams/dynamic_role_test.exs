defmodule Loomkin.Teams.DynamicRoleTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Agent, Context, Manager, TableRegistry}

  setup do
    {:ok, team_id} = Manager.create_team(name: "role-test", project_path: "/tmp/test-proj")

    on_exit(fn ->
      # Clean up agents
      for agent <- Manager.list_agents(team_id) do
        Manager.stop_agent(team_id, agent.name)
      end

      TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "change_role/3" do
    test "changes agent role successfully", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "flex-agent", :coder)
      assert :idle = Agent.get_status(pid)

      assert :ok = Agent.change_role(pid, :reviewer)

      # Verify via Registry metadata
      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "flex-agent"))
      assert agent.role == :reviewer
    end

    test "updates Context agent info", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "ctx-agent", :coder)

      Agent.change_role(pid, :researcher)

      {:ok, info} = Context.get_agent(team_id, "ctx-agent")
      assert info.role == :researcher
    end

    test "broadcasts role change to team", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "broadcast-agent", :coder)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")

      Agent.change_role(pid, :tester)

      assert_receive {:role_changed, "broadcast-agent", :coder, :tester}
    end

    test "returns error for unknown role", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "err-agent", :coder)

      assert {:error, :unknown_role} = Agent.change_role(pid, :nonexistent_role)

      # Role should remain unchanged
      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "err-agent"))
      assert agent.role == :coder
    end

    test "supports require_approval option", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "approval-agent", :coder)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")

      # With require_approval, it broadcasts a request then proceeds
      assert :ok = Agent.change_role(pid, :reviewer, require_approval: true)

      assert_receive {:role_change_request, "approval-agent", :coder, :reviewer, _request_id}
      assert_receive {:role_changed, "approval-agent", :coder, :reviewer}
    end

    test "multiple role changes in sequence", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "multi-agent", :coder)

      assert :ok = Agent.change_role(pid, :reviewer)
      assert :ok = Agent.change_role(pid, :tester)
      assert :ok = Agent.change_role(pid, :researcher)

      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "multi-agent"))
      assert agent.role == :researcher
    end
  end
end
