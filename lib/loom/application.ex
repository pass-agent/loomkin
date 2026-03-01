defmodule Loom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Auto-migrate in release mode
    if release_mode?(), do: Loom.Release.migrate()

    # Initialize tree-sitter symbol cache
    Loom.RepoIntel.TreeSitter.init_cache()

    # Create ETS table for Plug session store (must exist before endpoint starts)
    :ets.new(:loom_sessions, [:named_table, :public, :set])

    children =
      [
        # Storage
        Loom.Repo,

        # Configuration
        Loom.Config,

        # PubSub for session event broadcasting (always started — needed even without web server)
        {Phoenix.PubSub, name: Loom.PubSub},

        # Telemetry metrics aggregation
        Loom.Telemetry.Metrics,

        # Session registry for pid lookup by session_id
        {Registry, keys: :unique, name: Loom.SessionRegistry},

        # LSP server management (starts empty, reacts to :config_loaded)
        Loom.LSP.Supervisor,

        # Repo index
        Loom.RepoIntel.Index,

        # Session management
        {DynamicSupervisor, name: Loom.SessionSupervisor, strategy: :one_for_one},

        # Team agent orchestration
        Loom.Teams.Supervisor,

        # File watcher (starts idle, reacts to :config_loaded)
        Loom.RepoIntel.Watcher,

        # MCP client connections (starts empty, reacts to :config_loaded)
        Loom.MCP.ClientSupervisor
      ] ++
        maybe_start_mcp_server() ++
        maybe_start_endpoint()

    opts = [strategy: :one_for_one, name: Loom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_endpoint do
    if Application.get_env(:loom, LoomWeb.Endpoint)[:server] != false do
      [LoomWeb.Endpoint]
    else
      []
    end
  end

  defp maybe_start_mcp_server do
    if Loom.MCP.Server.enabled?() do
      Loom.MCP.Server.child_specs()
    else
      []
    end
  end

  defp release_mode? do
    # In a release, :code.priv_dir returns a path inside the release
    case :code.priv_dir(:loom) do
      {:error, _} -> false
      path -> path |> to_string() |> String.contains?("releases")
    end
  end
end
