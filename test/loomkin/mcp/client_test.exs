defmodule Loomkin.MCP.ClientTest do
  use ExUnit.Case

  alias Loomkin.MCP.Client

  describe "start_link/1" do
    test "starts the GenServer" do
      # Ensure no mcp servers configured so it won't try to connect
      Loomkin.Config.put(:mcp, %{servers: []})

      {:ok, pid} = Client.start_link(name: :test_mcp_client)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    after
      Loomkin.Config.put(:mcp, nil)
    end
  end

  describe "external_tools/0" do
    test "returns empty list when no servers configured" do
      Loomkin.Config.put(:mcp, %{servers: []})

      {:ok, pid} = Client.start_link([])
      # Give it a moment to process :connect
      Process.sleep(50)
      tools = GenServer.call(pid, :external_tools)
      assert tools == []
      GenServer.stop(pid)
    after
      Loomkin.Config.put(:mcp, nil)
    end
  end

  describe "external_tool_definitions/0" do
    test "returns empty list when client is not running" do
      assert Client.external_tool_definitions() == []
    end
  end

  describe "status/0" do
    test "returns empty map when no servers configured" do
      Loomkin.Config.put(:mcp, %{servers: []})

      {:ok, pid} = Client.start_link([])
      Process.sleep(50)
      status = GenServer.call(pid, :status)
      assert status == %{}
      GenServer.stop(pid)
    after
      Loomkin.Config.put(:mcp, nil)
    end
  end
end
