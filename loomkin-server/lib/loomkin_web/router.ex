defmodule LoomkinWeb.Router do
  use LoomkinWeb, :router

  import LoomkinWeb.UserAuth

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
  end

  scope "/api/webhooks" do
    post "/telegram", Loomkin.Channels.Telegram.Webhook, :handle
  end

  # REST API v1 — mobile client endpoints
  scope "/api/v1", LoomkinWeb.API.V1 do
    pipe_through :api

    post "/auth/login", AuthController, :login

    pipe_through LoomkinWeb.API.Auth

    get "/auth/me", AuthController, :me
    resources "/workspaces", WorkspaceController, only: [:index, :show]
    resources "/sessions", SessionController, only: [:create, :show]
    get "/sessions/:id/messages", SessionController, :messages
    post "/sessions/:id/messages", SessionController, :send_message
    post "/sessions/:id/cancel", SessionController, :cancel
    get "/teams/:id/agents", AgentController, :index
    post "/sessions/:session_id/approvals/approve", ApprovalController, :approve
    post "/sessions/:session_id/approvals/deny", ApprovalController, :deny
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

  # Mobile web routes — gated by multi-tenant auth (passes through in local mode)
  scope "/m", LoomkinWeb.Mobile do
    pipe_through [:browser, :require_auth_if_multi_tenant]

    live_session :mobile,
      on_mount: [{LoomkinWeb.UserAuth, :require_authenticated_if_multi_tenant}] do
      live "/", WorkspaceListLive, :index
      live "/workspaces/:id", SessionListLive, :index
      live "/sessions/:id", ChatLive, :show
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
