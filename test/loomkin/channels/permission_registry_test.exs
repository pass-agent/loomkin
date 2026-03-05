defmodule Loomkin.Channels.PermissionRegistryTest do
  use ExUnit.Case, async: false

  alias Loomkin.Channels.PermissionRegistry

  setup do
    # Ensure the ETS table exists and is clean for each test
    if :ets.whereis(:channel_permission_requests) != :undefined do
      :ets.delete_all_objects(:channel_permission_requests)
    end

    :ok
  end

  describe "register_request/5" do
    test "registers a request and returns an ID" do
      request_id =
        PermissionRegistry.register_request("team-1", "coder", "write_file", "/path/to/file.ex")

      assert is_binary(request_id)
      assert String.length(request_id) == 8
    end

    test "generates unique IDs" do
      id1 = PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")
      id2 = PermissionRegistry.register_request("team-1", "coder", "write_file", "/b.ex")

      assert id1 != id2
    end
  end

  describe "list_pending/1" do
    test "lists registered requests" do
      PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")
      PermissionRegistry.register_request("team-1", "researcher", "shell_command", "ls")

      pending = PermissionRegistry.list_pending("team-1")
      assert length(pending) == 2

      agents = Enum.map(pending, & &1.agent_name) |> Enum.sort()
      assert agents == ["coder", "researcher"]
    end

    test "filters by team_id" do
      PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")
      PermissionRegistry.register_request("team-2", "researcher", "shell_command", "ls")

      assert length(PermissionRegistry.list_pending("team-1")) == 1
      assert length(PermissionRegistry.list_pending("team-2")) == 1
    end

    test "returns all when team_id is nil" do
      PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")
      PermissionRegistry.register_request("team-2", "researcher", "shell_command", "ls")

      assert length(PermissionRegistry.list_pending(nil)) == 2
      assert length(PermissionRegistry.list_pending()) == 2
    end

    test "returns empty list when no requests" do
      assert PermissionRegistry.list_pending("team-x") == []
    end

    test "includes request metadata" do
      PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")

      [req] = PermissionRegistry.list_pending("team-1")
      assert req.team_id == "team-1"
      assert req.agent_name == "coder"
      assert req.tool_name == "write_file"
      assert req.tool_path == "/a.ex"
      assert is_integer(req.age_seconds)
      assert is_binary(req.request_id)
    end
  end

  describe "resolve_request/2" do
    test "returns :not_found for unknown request_id" do
      assert {:error, :not_found} = PermissionRegistry.resolve_request("nonexistent", "once")
    end

    test "removes request after resolution" do
      id = PermissionRegistry.register_request("team-1", "coder", "write_file", "/a.ex")

      # No agent is running so the lookup will fail, but the request is still removed
      PermissionRegistry.resolve_request(id, "once")

      assert PermissionRegistry.list_pending("team-1") == []
    end

    test "normalizes action values" do
      # Test that once/always/deny are accepted
      for action <- ["once", "always", "deny"] do
        id = PermissionRegistry.register_request("team-1", "agent-#{action}", "tool", "/path")
        # Will return {:error, :not_found} since no agent process exists,
        # but the request gets cleaned up
        PermissionRegistry.resolve_request(id, action)
        refute Enum.any?(PermissionRegistry.list_pending(), &(&1.request_id == id))
      end
    end
  end
end
