defmodule LoomkinWeb.TeamDashboardComponentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Loomkin.Teams.CostTracker
  alias Loomkin.Repo
  alias Loomkin.Schemas.TeamTask

  @team_id "test-team-dashboard"

  setup do
    CostTracker.init()
    :ok
  end

  describe "rendering" do
    test "renders team header with team_id" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "Kin:"
      assert html =~ @team_id
    end

    test "renders empty agent list" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "Agents"
      assert html =~ "No kin spawned"
    end

    test "renders empty task list" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "Tasks"
      assert html =~ "No tasks created"
    end

    test "renders budget bar" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "Budget"
      assert html =~ "0.00"
    end

    test "renders tasks when they exist" do
      {:ok, _task} =
        %TeamTask{}
        |> TeamTask.changeset(%{
          team_id: @team_id,
          title: "Implement auth module",
          status: :in_progress,
          owner: "researcher",
          priority: 1
        })
        |> Repo.insert()

      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "Implement auth module"
      assert html =~ "researcher"
    end

    test "renders budget percentage with green color for low usage" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id,
          budget: %{spent: 0.5, limit: 5.0}
        })

      # 10% -- green
      assert html =~ "bg-green-500"
    end
  end

  describe "agent count display" do
    test "shows 0 agents when no agents spawned" do
      html =
        render_component(LoomkinWeb.TeamDashboardComponent, %{
          id: "test-dashboard",
          team_id: @team_id
        })

      assert html =~ "0 agents"
    end
  end
end
