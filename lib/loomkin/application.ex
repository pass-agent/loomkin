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

        # Jido Signal Bus for typed event routing
        {Jido.Signal.Bus,
         name: Loomkin.SignalBus, journal_adapter: Jido.Signal.Journal.Adapters.ETS},

        # Telemetry metrics aggregation
        Loomkin.Telemetry.Metrics,

        # OAuth token storage (encrypted persistence + auto-refresh)
        Loomkin.Auth.TokenStore,

        # OAuth flow management (in-flight state, PKCE)
        Loomkin.Auth.OAuthServer,

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

        # Per-session TeamBroadcaster lifecycle
        {DynamicSupervisor, name: Loomkin.Teams.BroadcasterSupervisor, strategy: :one_for_one},

        # File watcher (starts idle, reacts to :config_loaded)
        Loomkin.RepoIntel.Watcher,

        # MCP client connections (starts empty, reacts to :config_loaded)
        Loomkin.MCP.ClientSupervisor,

        # Channel adapters (Telegram, Discord)
        Loomkin.Channels.Supervisor,

        # Self-healing: dedicated task supervisor for ephemeral agents (isolated from agent loops)
        {Task.Supervisor, name: Loomkin.Healing.TaskSupervisor},

        # Self-healing orchestrator (manages heal-diagnose-fix-resume lifecycle)
        {Loomkin.Healing.Orchestrator, shutdown: 15_000}
      ] ++
        maybe_start_mcp_server() ++
        maybe_start_endpoint()

    # Register custom OAuth providers with ReqLLM (before supervisor starts,
    # but after children list is defined — providers only call ReqLLM.Providers.register!
    # which has no runtime dependencies on the supervision tree)
    register_oauth_providers()

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

  defp register_oauth_providers do
    for module <- Loomkin.Auth.ProviderRegistry.reqllm_modules() do
      if Code.ensure_loaded?(module) and function_exported?(module, :register!, 0) do
        try do
          module.register!()
        rescue
          _e ->
            :ok
        end
      end
    end

    # Register local providers (Ollama)
    try do
      Loomkin.Providers.Ollama.register!()
    rescue
      _e -> :ok
    end
  end
end
