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

      # Wait for supervisor to restart the process (CI can be slow)
      {new_pid, _} = await_registry({:auto_logger, team_id}, old_pid)
      assert Process.alive?(new_pid)
    end

    test "Broadcaster restarts after crash", %{team_id: team_id} do
      [{old_pid, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {:broadcaster, team_id})
      Process.exit(old_pid, :kill)

      {new_pid, _} = await_registry({:broadcaster, team_id}, old_pid)
      assert Process.alive?(new_pid)
    end
  end

  describe "AutoLogger receives events after team creation" do
    test "logs agent_status events automatically", %{team_id: team_id} do
      # Emit a proper agent.status signal — AutoLogger subscribes to "agent.status"
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "test-agent",
          team_id: team_id,
          status: :working
        })

      Loomkin.Signals.publish(signal)

      [{logger_pid, _}] =
        Registry.lookup(Loomkin.Teams.AgentRegistry, {:auto_logger, team_id})

      Loomkin.Decisions.AutoLogger.flush(logger_pid)

      nodes = Loomkin.Decisions.Graph.list_nodes(node_type: :action)
      assert Enum.any?(nodes, &(&1.title == "Agent test-agent joined team"))
    end
  end

  # Poll Registry until a new pid (different from old_pid) appears, up to 5s.
  # On CI, the supervisor may take extra time due to concurrent test noise
  # (other tests' AutoLoggers crashing from DBConnection.OwnershipError).
  defp await_registry(key, old_pid, attempts \\ 100) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, key) do
      [{pid, val}] when pid != old_pid and is_pid(pid) ->
        if Process.alive?(pid), do: {pid, val}, else: await_registry(key, old_pid, attempts - 1)

      _ when attempts > 0 ->
        Process.sleep(50)
        await_registry(key, old_pid, attempts - 1)

      other ->
        flunk("Expected new pid for #{inspect(key)}, got: #{inspect(other)}")
    end
  end
end
