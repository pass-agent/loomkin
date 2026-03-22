defmodule Loomkin.Relay.Server.RegistryTest do
  use ExUnit.Case, async: false

  alias Loomkin.Relay.Server.Registry

  # The ETS table is created in application.ex on startup,
  # so it already exists. We just clean up after each test.

  setup do
    # Snapshot existing entries and restore after test
    existing = :ets.tab2list(:loomkin_relay_registry)

    on_exit(fn ->
      :ets.delete_all_objects(:loomkin_relay_registry)

      for entry <- existing do
        :ets.insert(:loomkin_relay_registry, entry)
      end
    end)

    # Start clean for each test
    :ets.delete_all_objects(:loomkin_relay_registry)
    :ok
  end

  defp sample_entry(overrides \\ %{}) do
    Map.merge(
      %{
        channel_pid: self(),
        machine_name: "test-machine",
        status: "active",
        team_id: nil,
        agent_count: 2,
        last_heartbeat: DateTime.utc_now(),
        project_path: "/home/user/project",
        workspace_name: "my-project"
      },
      overrides
    )
  end

  describe "register_workspace/3 and lookup_workspace/2" do
    test "stores entry and lookup returns it" do
      info = sample_entry()
      assert true == Registry.register_workspace(1, "ws-1", info)

      assert {:ok, stored} = Registry.lookup_workspace(1, "ws-1")
      assert stored.machine_name == "test-machine"
      assert stored.status == "active"
      assert stored.agent_count == 2
      assert stored.project_path == "/home/user/project"
      assert stored.workspace_name == "my-project"
    end

    test "lookup returns :error for missing entry" do
      assert :error = Registry.lookup_workspace(999, "nonexistent")
    end

    test "overwrites existing entry on re-register" do
      info1 = sample_entry(%{status: "active"})
      info2 = sample_entry(%{status: "idle"})

      Registry.register_workspace(1, "ws-1", info1)
      Registry.register_workspace(1, "ws-1", info2)

      assert {:ok, stored} = Registry.lookup_workspace(1, "ws-1")
      assert stored.status == "idle"
    end
  end

  describe "list_workspaces/1" do
    test "returns all workspaces for a user" do
      Registry.register_workspace(1, "ws-a", sample_entry(%{workspace_name: "alpha"}))
      Registry.register_workspace(1, "ws-b", sample_entry(%{workspace_name: "beta"}))
      Registry.register_workspace(2, "ws-c", sample_entry(%{workspace_name: "gamma"}))

      workspaces = Registry.list_workspaces(1)
      assert length(workspaces) == 2

      ids = Enum.map(workspaces, fn {id, _info} -> id end) |> Enum.sort()
      assert ids == ["ws-a", "ws-b"]
    end

    test "returns empty list for user with no workspaces" do
      assert Registry.list_workspaces(999) == []
    end
  end

  describe "unregister_daemon/1" do
    test "removes all entries for a given channel pid" do
      pid = self()
      other_pid = spawn(fn -> :timer.sleep(:infinity) end)

      Registry.register_workspace(1, "ws-1", sample_entry(%{channel_pid: pid}))
      Registry.register_workspace(1, "ws-2", sample_entry(%{channel_pid: pid}))
      Registry.register_workspace(2, "ws-3", sample_entry(%{channel_pid: other_pid}))

      assert :ok = Registry.unregister_daemon(pid)

      assert :error = Registry.lookup_workspace(1, "ws-1")
      assert :error = Registry.lookup_workspace(1, "ws-2")
      assert {:ok, _} = Registry.lookup_workspace(2, "ws-3")

      Process.exit(other_pid, :kill)
    end
  end

  describe "update_heartbeat/2" do
    test "updates the last_heartbeat timestamp" do
      old_time = DateTime.add(DateTime.utc_now(), -60, :second)
      Registry.register_workspace(1, "ws-1", sample_entry(%{last_heartbeat: old_time}))

      before_update = DateTime.utc_now()
      :ok = Registry.update_heartbeat(1, "ws-1")

      {:ok, entry} = Registry.lookup_workspace(1, "ws-1")
      assert DateTime.compare(entry.last_heartbeat, before_update) in [:eq, :gt]
    end

    test "no-op for missing entry" do
      assert :ok = Registry.update_heartbeat(999, "nonexistent")
    end
  end

  describe "update_workspace/3" do
    test "merges changes into existing entry" do
      Registry.register_workspace(1, "ws-1", sample_entry(%{status: "active", agent_count: 2}))

      :ok = Registry.update_workspace(1, "ws-1", %{status: "idle", agent_count: 0})

      {:ok, entry} = Registry.lookup_workspace(1, "ws-1")
      assert entry.status == "idle"
      assert entry.agent_count == 0
      # Unchanged fields remain
      assert entry.machine_name == "test-machine"
    end

    test "no-op for missing entry" do
      assert :ok = Registry.update_workspace(999, "nonexistent", %{status: "idle"})
    end
  end

  describe "all_entries/0" do
    test "returns all entries in the table" do
      Registry.register_workspace(1, "ws-1", sample_entry())
      Registry.register_workspace(2, "ws-2", sample_entry())

      entries = Registry.all_entries()
      assert length(entries) == 2
    end
  end
end
