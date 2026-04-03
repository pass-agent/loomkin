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
      Loomkin.Signals.subscribe("agent.role.changed")

      Agent.change_role(pid, :tester)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "agent.role.changed",
                        data: %{
                          agent_name: "broadcast-agent",
                          old_role: :coder,
                          new_role: :tester
                        }
                      }}
    end

    test "returns error for unknown role", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "err-agent", :coder)

      assert {:error, :unknown_role} = Agent.change_role(pid, :nonexistent_role)

      # Role should remain unchanged
      agents = Manager.list_agents(team_id)
      agent = Enum.find(agents, &(&1.name == "err-agent"))
      assert agent.role == :coder
    end

    test "broadcasts role changed signal", %{team_id: team_id} do
      {:ok, pid} = Manager.spawn_agent(team_id, "approval-agent", :coder)
      # Allow init signals to settle before subscribing
      Process.sleep(50)
      Loomkin.Signals.subscribe("agent.**")

      assert :ok = Agent.change_role(pid, :reviewer)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "agent.role.changed",
                        data: %{
                          agent_name: "approval-agent",
                          old_role: :coder,
                          new_role: :reviewer
                        }
                      }},
                     500
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
