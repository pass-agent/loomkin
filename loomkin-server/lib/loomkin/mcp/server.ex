defmodule Loomkin.MCP.Server do
  @moduledoc """
  MCP server that exposes Loomkin's built-in tools to external editors.

  Uses jido_mcp's `Jido.MCP.Server` macro to declare which tools are published.
  External MCP clients (VS Code, Cursor, Zed, etc.) connect via stdio or HTTP
  and can discover/invoke all 11 Loomkin tools through the MCP protocol.

  Configuration via `.loomkin.toml`:

      [mcp]
      server_enabled = true

  The server is started conditionally in the supervision tree based on config.
  """

  use Jido.MCP.Server,
    name: "loom",
    version: "0.1.0",
    publish: %{
      tools: [
        Loomkin.Tools.FileRead,
        Loomkin.Tools.FileWrite,
        Loomkin.Tools.FileEdit,
        Loomkin.Tools.FileSearch,
        Loomkin.Tools.ContentSearch,
        Loomkin.Tools.DirectoryList,
        Loomkin.Tools.Shell,
        Loomkin.Tools.Git,
        Loomkin.Tools.DecisionLog,
        Loomkin.Tools.DecisionQuery,
        Loomkin.Tools.SubAgent
      ],
      resources: [],
      prompts: []
    }

  @doc """
  Returns the child specs for the MCP server processes.

  Options:
    - `:transport` - `:stdio` (default) or `{:streamable_http, opts}`
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    Jido.MCP.Server.server_children(__MODULE__, opts)
  end

  @doc """
  Returns true if the MCP server should be started based on config.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Loomkin.Config.get(:mcp) do
      %{server_enabled: true} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end
end
