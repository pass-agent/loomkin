defmodule LoomkinWeb.OrchestrationLiveTest do
  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "GET /orchestration renders the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/orchestration")

    assert html =~ "Orchestration epics"
    assert html =~ "Start a new epic"
  end

  test "GET /orchestration/:id 404-style redirects when the epic does not exist", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/orchestration"}}} =
      live(conn, "/orchestration/" <> Ecto.UUID.generate())
  end
end
