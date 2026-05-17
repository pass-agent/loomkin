defmodule LoomkinWeb.OrchestrationKnowledgeLiveTest do
  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loomkin.Orchestration.KnowledgeStore

  setup :register_and_log_in_user

  setup do
    {:ok, _} =
      KnowledgeStore.put_fact(%{
        type: :pattern,
        fact: "prefer gen_statem :state_timeout 0 over :next_event in :enter",
        recommendation: "use state_timeout",
        confidence: :medium,
        tags: ["elixir", "gen_statem"],
        provenance: [%{"source" => "human", "reference" => "test fixture"}]
      })

    :ok
  end

  test "GET /orchestration/knowledge lists facts and exposes promotion", %{conn: conn} do
    {:ok, view, html} = live(conn, "/orchestration/knowledge")

    assert html =~ "Knowledge base"
    assert html =~ "state_timeout"
    assert has_element?(view, "button", "promote to high")
  end

  test "filtering by confidence narrows the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/orchestration/knowledge")

    # Filter to :high — our fixture is :medium, so list should empty out
    rendered =
      view
      |> form("form", filters: %{type: "", confidence: "high", tag: ""})
      |> render_change()

    assert rendered =~ "No facts match"
  end

  test "promote button advances a medium fact to high", %{conn: conn} do
    {:ok, view, _} = live(conn, "/orchestration/knowledge")

    # Click the first promote button
    rendered =
      view
      |> element("button[phx-click='promote']")
      |> render_click()

    assert rendered =~ "high"
    refute rendered =~ "promote to high"
  end
end
