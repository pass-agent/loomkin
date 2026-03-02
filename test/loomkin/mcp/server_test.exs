defmodule Loomkin.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Loomkin.MCP.Server

  describe "module configuration" do
    test "publishes all 11 Loomkin tools" do
      publish = Server.__publish__()
      assert is_map(publish)
      assert is_list(publish.tools)
      assert length(publish.tools) == 11

      tool_modules = publish.tools
      assert Loomkin.Tools.FileRead in tool_modules
      assert Loomkin.Tools.FileWrite in tool_modules
      assert Loomkin.Tools.FileEdit in tool_modules
      assert Loomkin.Tools.FileSearch in tool_modules
      assert Loomkin.Tools.ContentSearch in tool_modules
      assert Loomkin.Tools.DirectoryList in tool_modules
      assert Loomkin.Tools.Shell in tool_modules
      assert Loomkin.Tools.Git in tool_modules
      assert Loomkin.Tools.DecisionLog in tool_modules
      assert Loomkin.Tools.DecisionQuery in tool_modules
      assert Loomkin.Tools.SubAgent in tool_modules
    end

    test "publishes no resources or prompts" do
      publish = Server.__publish__()
      assert publish.resources == []
      assert publish.prompts == []
    end
  end

  describe "child_specs/1" do
    test "returns a list of child specs" do
      specs = Server.child_specs()
      assert is_list(specs)
      assert length(specs) == 2
    end

    test "includes Anubis.Server.Registry" do
      specs = Server.child_specs()
      assert Anubis.Server.Registry in specs
    end

    test "includes server module child spec" do
      specs = Server.child_specs()
      {module, opts} = Enum.find(specs, fn spec -> is_tuple(spec) end)
      assert module == Loomkin.MCP.Server
      assert Keyword.has_key?(opts, :transport)
    end

    test "defaults to stdio transport" do
      specs = Server.child_specs()
      {_module, opts} = Enum.find(specs, fn spec -> is_tuple(spec) end)
      assert opts[:transport] == :stdio
    end

    test "accepts custom transport option" do
      specs = Server.child_specs(transport: {:streamable_http, port: 8080})
      {_module, opts} = Enum.find(specs, fn spec -> is_tuple(spec) end)
      assert opts[:transport] == {:streamable_http, port: 8080}
    end
  end

  describe "enabled?/0" do
    test "returns false when mcp config is nil" do
      # Config is loaded with defaults which don't include mcp
      refute Server.enabled?()
    end

    test "returns true when server_enabled is true in config" do
      Loomkin.Config.put(:mcp, %{server_enabled: true})
      assert Server.enabled?()
      # Clean up
      Loomkin.Config.put(:mcp, nil)
    end

    test "returns false when server_enabled is false" do
      Loomkin.Config.put(:mcp, %{server_enabled: false})
      refute Server.enabled?()
      # Clean up
      Loomkin.Config.put(:mcp, nil)
    end
  end

  describe "MCP server callbacks" do
    test "defines handle_tool_call/3" do
      assert function_exported?(Server, :handle_tool_call, 3)
    end

    test "defines handle_resource_read/2" do
      assert function_exported?(Server, :handle_resource_read, 2)
    end

    test "defines handle_prompt_get/3" do
      assert function_exported?(Server, :handle_prompt_get, 3)
    end

    test "defines authorize/2" do
      assert function_exported?(Server, :authorize, 2)
    end

    test "authorize/2 returns :ok by default" do
      assert :ok == Server.authorize(%{}, %{})
    end
  end
end
