defmodule LoomkinWeb.CostDashboardLiveTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders dashboard with core sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Cost Dashboard"
      assert html =~ "Total Cost"
      assert html =~ "Total Tokens"
      assert html =~ "LLM Requests"
      assert html =~ "Sessions"
      assert html =~ "Model Usage"
      assert html =~ "Tool Execution"
    end

    test "shows back to workspace link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Back to Workspace"
    end
  end

  describe "live updates" do
    test "displays session data from telemetry events", %{conn: conn} do
      session_id = "lv-test-#{System.unique_integer([:positive])}"

      # Emit a telemetry event before connecting
      :telemetry.execute(
        [:loomkin, :llm, :request, :stop],
        %{duration: System.convert_time_unit(100, :millisecond, :native)},
        %{
          session_id: session_id,
          model: "anthropic:claude-lv-test",
          input_tokens: 500,
          output_tokens: 200,
          total_cost: 0.01
        }
      )

      Process.sleep(50)

      {:ok, view, _html} = live(conn, "/dashboard")

      html = render(view)
      assert html =~ String.slice(session_id, 0, 8)
      assert html =~ "anthropic:claude-lv-test"
    end

    test "updates in real-time when new events arrive", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      session_id = "realtime-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:loomkin, :llm, :request, :stop],
        %{duration: System.convert_time_unit(50, :millisecond, :native)},
        %{
          session_id: session_id,
          model: "openai:gpt-realtime",
          input_tokens: 1000,
          output_tokens: 500,
          total_cost: 0.02
        }
      )

      # Wait for the GenServer.cast to update ETS, then trigger a re-render.
      # The broadcast_update() in the telemetry handler fires before the GenServer
      # processes the cast, so the first re-render may read stale ETS data.
      Process.sleep(100)
      Loomkin.Signals.publish(Loomkin.Signals.System.MetricsUpdated.new!())
      Process.sleep(50)

      html = render(view)
      assert html =~ String.slice(session_id, 0, 8)
    end
  end
end
