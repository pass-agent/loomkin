defmodule Loomkin.Decisions.SupervisionTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Manager

  setup do
    # Enable nervous system auto-start for these tests
    prev = Application.get_env(:loomkin, :start_nervous_system)
    Application.put_env(:loomkin, :start_nervous_system, true)

    {:ok, team_id} = Manager.create_team(name: "supervision-test")

    on_exit(fn ->
      Manager.dissolve_team(team_id)

      if is_nil(prev),
        do: Application.delete_env(:loomkin, :start_nervous_system),
        else: Application.put_env(:loomkin, :start_nervous_system, prev)
    end)

    %{team_id: team_id}
  end

  describe "team creation starts nervous system" do
    test "AutoLogger is running after create_team", %{team_id: team_id} do
      [{pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})
      assert Process.alive?(pid)
    end

    test "Broadcaster is running after create_team", %{team_id: team_id} do
      [{pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id})
      assert Process.alive?(pid)
    end
  end

  describe "sub-team creation starts nervous system" do
    test "AutoLogger and Broadcaster start for sub-teams", %{team_id: parent_id} do
      {:ok, sub_id} = Manager.create_sub_team(parent_id, "lead", name: "sub-team")

      [{auto_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, sub_id})
      [{broad_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, sub_id})

      assert Process.alive?(auto_pid)
      assert Process.alive?(broad_pid)

      Manager.dissolve_team(sub_id)
    end
  end

  describe "team dissolution stops nervous system" do
    test "AutoLogger and Broadcaster stop on dissolve_team" do
      {:ok, team_id} = Manager.create_team(name: "dissolve-ns-test")

      [{auto_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})
      [{broad_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id})

      assert Process.alive?(auto_pid)
      assert Process.alive?(broad_pid)

      Manager.dissolve_team(team_id)

      refute Process.alive?(auto_pid)
      refute Process.alive?(broad_pid)

      assert Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id}) == []
      assert Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id}) == []
    end

    test "dissolve is safe when nervous system already stopped" do
      {:ok, team_id} = Manager.create_team(name: "double-dissolve-test")

      # Manually stop the processes first
      [{auto_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})
      GenServer.stop(auto_pid)
      Process.sleep(20)

      # dissolve_team should still succeed
      assert :ok = Manager.dissolve_team(team_id)
    end
  end

  describe "nervous system processes are supervised" do
    test "AutoLogger restarts after crash", %{team_id: team_id} do
      [{old_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})
      Process.exit(old_pid, :kill)
      Process.sleep(100)

      # DynamicSupervisor should restart it with a new pid
      result = Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})
      assert [{new_pid, _}] = result
      assert Process.alive?(new_pid)
      assert new_pid != old_pid
    end

    test "Broadcaster restarts after crash", %{team_id: team_id} do
      [{old_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id})
      Process.exit(old_pid, :kill)
      Process.sleep(100)

      result = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id})
      assert [{new_pid, _}] = result
      assert Process.alive?(new_pid)
      assert new_pid != old_pid
    end
  end

  describe "AutoLogger receives events after team creation" do
    test "logs agent_status events automatically", %{team_id: team_id} do
      # Broadcast an event — AutoLogger should create a graph node
      Loomkin.Teams.Comms.broadcast(team_id, {:agent_status, "test-agent", :working})
      Process.sleep(50)

      nodes = Loomkin.Decisions.Graph.list_nodes(node_type: :action)
      assert Enum.any?(nodes, &(&1.title == "Agent test-agent joined team"))
    end
  end
end
