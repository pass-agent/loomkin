defmodule LoomkinWeb.TeamCostComponentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Loomkin.Teams.CostTracker

  @team_id "test-team-cost"

  setup do
    CostTracker.init()
    # Reset any previous test data for this team
    CostTracker.reset_team(@team_id)
    :ok
  end

  describe "rendering" do
    test "renders budget gauge section" do
      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "Budget"
      assert html =~ "spent"
    end

    test "renders agent token usage section" do
      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "Agent Token Usage"
    end

    test "renders model costs section" do
      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "Model Costs"
    end

    test "shows no agent data message when empty" do
      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "No agent data yet"
      assert html =~ "No model data yet"
    end

    test "renders agent cost data after recording usage" do
      CostTracker.record_usage(@team_id, "researcher", %{
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.02,
        model: "anthropic:claude-sonnet-4-6"
      })

      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "researcher"
      assert html =~ "tok"
    end
  end

  describe "budget color thresholds" do
    test "shows green for low usage (no agent spending)" do
      # No agent costs recorded = 0% usage = green
      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "bg-green-500"
      assert html =~ "text-green-400"
    end

    test "shows yellow for medium usage (50-79%)" do
      # Record enough cost to reach ~60% of the $5.00 default budget
      CostTracker.record_usage(@team_id, "big-spender", %{
        input_tokens: 100_000,
        output_tokens: 50_000,
        cost: 3.0,
        model: "anthropic:claude-opus-4-6"
      })

      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "bg-yellow-500"
      assert html =~ "text-yellow-400"
    end

    test "shows red for high usage (80%+)" do
      # Record enough cost to reach ~90% of the $5.00 default budget
      CostTracker.record_usage(@team_id, "max-spender", %{
        input_tokens: 200_000,
        output_tokens: 100_000,
        cost: 4.5,
        model: "anthropic:claude-opus-4-6"
      })

      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "bg-red-500"
      assert html =~ "text-red-400"
    end
  end

  describe "model breakdown" do
    test "shows model cost data after recording calls" do
      CostTracker.record_usage(@team_id, "coder", %{
        input_tokens: 2000,
        output_tokens: 800,
        cost: 0.05,
        model: "anthropic:claude-opus-4-6"
      })

      CostTracker.record_call(@team_id, "coder", %{
        model: "anthropic:claude-opus-4-6",
        input_tokens: 2000,
        output_tokens: 800,
        cost: 0.05,
        timestamp: DateTime.utc_now()
      })

      html = render_component(LoomkinWeb.TeamCostComponent, %{
        id: "test-cost",
        team_id: @team_id
      })

      assert html =~ "claude-opus-4-6"
    end
  end
end
