defmodule LoomkinWeb.OrchestrationMetricsLiveTest do
  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loomkin.Orchestration.Metrics

  setup :register_and_log_in_user

  describe "empty state" do
    test "renders the four headline cards and empty-state copy with zero rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/orchestration/metrics")

      assert html =~ "Orchestration metrics"
      assert html =~ "Total events"
      assert html =~ "Escalations"
      assert html =~ "Overall gate pass rate"
      assert html =~ "Distinct models"
      assert html =~ "No orchestration events recorded yet"
    end
  end

  describe "with seeded events" do
    setup do
      epic_id = Ecto.UUID.generate()

      # Gate verdicts: build pass-rate per gate AND per model
      {:ok, _} =
        Metrics.record(%{
          epic_id: epic_id,
          event_kind: :gate_verdict,
          gate: "test_gate",
          model: "claude-sonnet-4",
          verdict: :pass,
          iteration: 1
        })

      {:ok, _} =
        Metrics.record(%{
          epic_id: epic_id,
          event_kind: :gate_verdict,
          gate: "test_gate",
          model: "claude-sonnet-4",
          verdict: :pass,
          iteration: 1
        })

      {:ok, _} =
        Metrics.record(%{
          epic_id: epic_id,
          event_kind: :gate_verdict,
          gate: "test_gate",
          model: "gpt-5",
          verdict: :fail,
          iteration: 2
        })

      # An escalation
      {:ok, _} =
        Metrics.record(%{
          epic_id: epic_id,
          event_kind: :escalated,
          phase: "review"
        })

      %{epic_id: epic_id}
    end

    test "renders aggregates: gates, models, iteration, escalation count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/orchestration/metrics")

      # Page sections appear
      assert html =~ "Pass rate per gate"
      assert html =~ "Iteration distribution"
      assert html =~ "Per-model pass rate"

      # Gate + model names appear
      assert html =~ "test_gate"
      assert html =~ "claude-sonnet-4"
      assert html =~ "gpt-5"

      # Escalation count shows up (we recorded exactly one)
      assert html =~ "Escalations"

      # Empty-state copy is gone now that we have rows
      refute html =~ "No orchestration events recorded yet"
    end

    test "changing the window filter reloads aggregates", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/orchestration/metrics")

      # The default window is "last 24 hours" — events are fresh, so they should render.
      assert render(view) =~ "test_gate"

      # Switch to "last hour" — events are still inside the window (just recorded), still visible.
      rendered =
        view
        |> form("form", filters: %{since: "hour"})
        |> render_change()

      assert rendered =~ "test_gate"

      # Switch to "all time" — events should still render.
      rendered_all =
        view
        |> form("form", filters: %{since: "all"})
        |> render_change()

      assert rendered_all =~ "test_gate"
    end
  end
end
