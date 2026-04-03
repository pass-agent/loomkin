defmodule LoomkinWeb.WorkspaceLiveTreeTest do
  use LoomkinWeb.ConnCase

  alias LoomkinWeb.WorkspaceLive

  describe "team_tree assign" do
    test "team_tree is empty map on mount with no sub-teams" do
      socket = build_test_socket(team_tree: %{}, team_names: %{})
      assert socket.assigns.team_tree == %{}
      assert socket.assigns.team_names == %{}
    end

    test "team_tree updated on :child_team_created signal" do
      parent_id = "parent-team-1"
      child_id = "child-team-abc"
      team_name = "Research Team"

      socket = build_test_socket(team_tree: %{}, team_names: %{}, team_id: parent_id)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:child_team_created, child_id, parent_id, team_name},
          socket
        )

      assert updated_socket.assigns.team_tree == %{parent_id => [child_id]}
      assert updated_socket.assigns.team_names[child_id] == team_name
    end

    test "team_tree removes dissolved team and its descendants" do
      parent_id = "parent-team-1"
      child_id = "child-team-abc"
      grandchild_id = "grandchild-team-xyz"

      # Build a tree: parent -> [child], child -> [grandchild]
      tree = %{parent_id => [child_id], child_id => [grandchild_id]}
      names = %{child_id => "Research", grandchild_id => "Sub-Research"}

      socket =
        build_test_socket(
          team_tree: tree,
          team_names: names,
          team_id: parent_id,
          subscribed_teams: MapSet.new([parent_id, child_id, grandchild_id])
        )

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info({:team_dissolved, child_id}, socket)

      # child and grandchild should be removed from tree
      assert updated_socket.assigns.team_tree == %{parent_id => []}
      # names should be pruned
      assert Map.has_key?(updated_socket.assigns.team_names, child_id) == false
      assert Map.has_key?(updated_socket.assigns.team_names, grandchild_id) == false
    end

    test "workspace_live subscribes to child team on ChildTeamCreated signal" do
      parent_id = "parent-team-subscribe"
      child_id = "child-subscribe-abc"
      team_name = "Subscriber Team"

      socket = build_test_socket(team_tree: %{}, team_names: %{}, team_id: parent_id)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:child_team_created, child_id, parent_id, team_name},
          socket
        )

      # child team should now be in subscribed_teams
      assert MapSet.member?(updated_socket.assigns.subscribed_teams, child_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_test_socket(opts) do
    team_id = Keyword.get(opts, :team_id, "team-root")
    team_tree = Keyword.get(opts, :team_tree, %{})
    team_names = Keyword.get(opts, :team_names, %{})
    subscribed_teams = Keyword.get(opts, :subscribed_teams, MapSet.new([team_id]))

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :show,
        team_id: team_id,
        active_team_id: team_id,
        mode: :mission_control,
        team_tree: team_tree,
        team_names: team_names,
        subscribed_teams: subscribed_teams,
        cached_agents: [],
        agent_cards: %{},
        concierge_card_names: [],
        worker_card_names: [],
        comms_event_count: 0,
        activity_event_count: 0,
        activity_known_agents: [],
        buffered_activity_events: [],
        broadcaster: nil,
        roster_refresh_timer: nil
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
