defmodule Loomkin.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Auto-migrate in release mode
    if release_mode?(), do: Loomkin.Release.migrate()

    # Initialize tree-sitter symbol cache
    Loomkin.RepoIntel.TreeSitter.init_cache()

    # Create ETS table for Plug session store (must exist before endpoint starts)
    :ets.new(:loomkin_sessions, [:named_table, :public, :set])

    children =
      [
        # Storage
        Loomkin.Repo,

        # Configuration
        Loomkin.Config,

        # PubSub for session event broadcasting (always started — needed even without web server)
        {Phoenix.PubSub, name: Loomkin.PubSub},

        # Telemetry metrics aggregation
        Loomkin.Telemetry.Metrics,

        # Session registry for pid lookup by session_id
        {Registry, keys: :unique, name: Loomkin.SessionRegistry},

        # LSP server management (starts empty, reacts to :config_loaded)
        Loomkin.LSP.Supervisor,

        # Repo index
        Loomkin.RepoIntel.Index,

        # Session management
        {DynamicSupervisor, name: Loomkin.SessionSupervisor, strategy: :one_for_one},

        # Team agent orchestration
        Loomkin.Teams.Supervisor,

        # File watcher (starts idle, reacts to :config_loaded)
        Loomkin.RepoIntel.Watcher,

        # MCP client connections (starts empty, reacts to :config_loaded)
        Loomkin.MCP.ClientSupervisor
      ] ++
        maybe_start_mcp_server() ++
        maybe_start_endpoint()

    opts = [strategy: :one_for_one, name: Loomkin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_endpoint do
    if Application.get_env(:loomkin, LoomkinWeb.Endpoint)[:server] != false do
      [LoomkinWeb.Endpoint]
    else
      []
    end
  end

  defp maybe_start_mcp_server do
    if Loomkin.MCP.Server.enabled?() do
      Loomkin.MCP.Server.child_specs()
    else
      []
    end
  end

  defp release_mode? do
    # In a release, :code.priv_dir returns a path inside the release
    case :code.priv_dir(:loomkin) do
      {:error, _} -> false
      path -> path |> to_string() |> String.contains?("releases")
    end
  end
end
