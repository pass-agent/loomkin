defmodule LoomkinWeb.TeamTreeComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LoomkinWeb.TeamTreeComponent

  @base_assigns %{
    id: "team-tree-test",
    team_tree: %{"root-team" => ["child-team-1"]},
    root_team_id: "root-team",
    active_team_id: "root-team",
    agent_counts: %{"root-team" => 2, "child-team-1" => 1},
    team_names: %{"child-team-1" => "Research Team"}
  }

  describe "TeamTreeComponent" do
    test "component is hidden when team_tree is empty" do
      html =
        render_component(TeamTreeComponent,
          id: "team-tree-test",
          team_tree: %{},
          root_team_id: "root-team",
          active_team_id: "root-team",
          agent_counts: %{},
          team_names: %{}
        )

      refute html =~ "Teams"
    end

    test "component renders trigger button when sub-teams exist" do
      html = render_component(TeamTreeComponent, @base_assigns)
      assert html =~ "Teams"
    end

    test "toggle_tree opens and closes the dropdown" do
      socket = build_component_socket(open: false)

      {:noreply, opened_socket} =
        TeamTreeComponent.handle_event("toggle_tree", %{}, socket)

      assert opened_socket.assigns.open == true

      {:noreply, closed_socket} =
        TeamTreeComponent.handle_event("toggle_tree", %{}, opened_socket)

      assert closed_socket.assigns.open == false
    end

    test "selecting a tree node sends switch_team to parent" do
      socket = build_component_socket(open: true)

      {:noreply, updated_socket} =
        TeamTreeComponent.handle_event("select_team", %{"team-id" => "child-team-1"}, socket)

      # dropdown should close
      assert updated_socket.assigns.open == false

      # parent (test process) should receive {:switch_team, team_id}
      assert_received {:switch_team, "child-team-1"}
    end

    test "kill_team first click sets confirm_kill, second click sends message" do
      socket = build_component_socket(open: true)

      # First click: enters confirmation state
      {:noreply, confirming} =
        TeamTreeComponent.handle_event("kill_team", %{"team-id" => "child-team-1"}, socket)

      assert confirming.assigns.confirm_kill == "child-team-1"
      refute_received {:kill_team, _}

      # Second click: sends kill message and closes
      {:noreply, killed} =
        TeamTreeComponent.handle_event("kill_team", %{"team-id" => "child-team-1"}, confirming)

      assert killed.assigns.open == false
      assert killed.assigns.confirm_kill == nil
      assert_received {:kill_team, "child-team-1"}
    end

    test "cancel_kill resets confirm_kill state" do
      socket = build_component_socket(open: true)

      {:noreply, confirming} =
        TeamTreeComponent.handle_event("kill_team", %{"team-id" => "child-team-1"}, socket)

      assert confirming.assigns.confirm_kill == "child-team-1"

      {:noreply, cancelled} =
        TeamTreeComponent.handle_event("cancel_kill", %{}, confirming)

      assert cancelled.assigns.confirm_kill == nil
    end

    test "kill_all_teams sets confirm_kill to :all" do
      socket = build_component_socket(open: true)

      {:noreply, confirming} =
        TeamTreeComponent.handle_event("kill_all_teams", %{}, socket)

      assert confirming.assigns.confirm_kill == :all
    end

    test "confirm_kill_all sends :kill_all_teams and closes" do
      socket = build_component_socket(open: true)

      {:noreply, confirming} =
        TeamTreeComponent.handle_event("kill_all_teams", %{}, socket)

      {:noreply, killed} =
        TeamTreeComponent.handle_event("confirm_kill_all", %{}, confirming)

      assert killed.assigns.open == false
      assert killed.assigns.confirm_kill == nil
      assert_received :kill_all_teams
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_component_socket(opts) do
    open = Keyword.get(opts, :open, false)

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "team-tree-test",
        open: open,
        confirm_kill: nil,
        team_tree: %{"root-team" => ["child-team-1"]},
        root_team_id: "root-team",
        active_team_id: "root-team",
        agent_counts: %{"root-team" => 2, "child-team-1" => 1},
        team_names: %{"child-team-1" => "Research Team"},
        myself: nil
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }
  end
end
