defmodule LoomkinWeb.Router do
  use LoomkinWeb, :router

  import LoomkinWeb.UserAuth
  import LoomkinWeb.ApiAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoomkinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug CORSPlug
    plug :fetch_api_user
  end

  # ── JSON API v1 ─────────────────────────────────────────────────────
  # Public API routes (no auth required)
  scope "/api/v1", LoomkinWeb.Api, as: :api do
    pipe_through :api

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/login/confirm", AuthController, :confirm
    post "/auth/anonymous", AuthController, :anonymous
  end

  # Authenticated API routes (bearer token required)
  scope "/api/v1", LoomkinWeb.Api, as: :api do
    pipe_through [:api, :require_api_auth]

    post "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    resources "/sessions", SessionController, only: [:index, :show, :create, :update]
    get "/sessions/:id/messages", SessionController, :messages
    post "/sessions/:id/messages", SessionController, :send_message
    patch "/sessions/:id/archive", SessionController, :archive

    get "/teams/:team_id", TeamController, :show
    get "/teams/:team_id/agents", TeamController, :agents

    get "/models", ModelController, :index
    get "/models/providers", ModelController, :providers

    get "/settings", SettingController, :index
    put "/settings", SettingController, :update

    get "/mcp", McpController, :index
    post "/mcp/refresh", McpController, :refresh

    get "/diff", DiffController, :index

    get "/files", FilesController, :index
    get "/files/read", FilesController, :read
    get "/files/search", FilesController, :search
    get "/files/grep", FilesController, :grep

    get "/decisions", DecisionController, :index

    resources "/backlog", BacklogController, except: [:new, :edit]

    post "/sessions/:session_id/shares", ShareController, :create
    get "/sessions/:session_id/shares", ShareController, :index
    delete "/shares/:id", ShareController, :delete
  end

  # CORS preflight for API routes
  options "/api/v1/*path", LoomkinWeb.Api.FallbackController, :options

  scope "/api/webhooks" do
    post "/telegram", Loomkin.Channels.Telegram.Webhook, :handle
  end

  # OAuth provider authentication routes — must be before the catch-all "/" scope
  scope "/auth", LoomkinWeb do
    pipe_through :browser

    get "/:provider", AuthController, :authorize
    get "/:provider/callback", AuthController, :callback
    post "/:provider/paste", AuthController, :paste
    delete "/:provider", AuthController, :disconnect
    get "/:provider/status", AuthController, :status
  end

  ## Authentication routes (only active in multi-tenant mode)

  scope "/", LoomkinWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", LoomkinWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", LoomkinWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Public social routes — accessible without authentication
  scope "/", LoomkinWeb do
    pipe_through [:browser]

    live_session :public_social,
      on_mount: [{LoomkinWeb.UserAuth, :mount_current_scope}] do
      live "/explore", ExploreLive, :index
      live "/@:username", ProfileLive, :show
      live "/@:username/:slug", SnippetLive, :show
    end
  end

  # Authenticated social routes — require login in deployed mode, pass through in local mode
  scope "/", LoomkinWeb do
    pipe_through [:browser, :require_auth_if_multi_tenant]

    live_session :authenticated_social,
      on_mount: [{LoomkinWeb.UserAuth, :require_authenticated_if_multi_tenant}] do
      live "/snippets/new", SnippetLive, :new
      live "/snippets/:id/edit", SnippetLive, :edit
    end
  end

  # Homepage — accessible to everyone (authenticated or not)
  # Shows community feed + trending for visitors, full dashboard for logged-in users
  # In local mode, redirects to project picker
  scope "/", LoomkinWeb do
    pipe_through [:browser]

    live_session :home,
      on_mount: [{LoomkinWeb.UserAuth, :mount_current_scope}] do
      live "/", HomeLive, :index
    end
  end

  # Org routes — require authentication (multi-tenant only)
  scope "/", LoomkinWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :orgs,
      on_mount: [{LoomkinWeb.UserAuth, :require_authenticated_user}] do
      live "/orgs", OrgLive, :index
      live "/orgs/new", OrgLive, :new
      live "/orgs/:slug", OrgLive, :show
    end
  end

  # App routes — gated by multi-tenant auth (passes through in local mode)
  scope "/", LoomkinWeb do
    pipe_through [:browser, :require_auth_if_multi_tenant]

    live_session :app,
      on_mount: [{LoomkinWeb.UserAuth, :mount_current_scope}] do
      live "/projects", ProjectPickerLive, :index
      live "/sessions/new", WorkspaceLive, :new
      live "/sessions/:session_id", WorkspaceLive, :show
      live "/dashboard", CostDashboardLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: false
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
