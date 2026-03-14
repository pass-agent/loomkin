defmodule LoomkinWeb.Router do
  use LoomkinWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoomkinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

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

  scope "/", LoomkinWeb do
    pipe_through :browser

    live "/", ProjectPickerLive, :index
    live "/sessions/new", WorkspaceLive, :new
    live "/sessions/:session_id", WorkspaceLive, :show
    live "/dashboard", CostDashboardLive, :index
    live "/settings", SettingsLive, :index
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: false
    end
  end
end
