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

  scope "/", LoomkinWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
    live "/sessions/:session_id", WorkspaceLive, :show
    live "/dashboard", CostDashboardLive, :index
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: false
    end
  end
end
