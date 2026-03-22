defmodule Loomkin.Teams.AgentChildTeamsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Manager

  defp unique_team_id do
    "test-team-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(overrides \\ []) do
    team_id = Keyword.get(overrides, :team_id, unique_team_id())
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)

    opts =
      [team_id: team_id, name: name, role: role]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name, role: role}
  end

  describe "spawned_child_teams field" do
    test "spawned_child_teams defaults to empty list" do
      %{pid: pid} = start_agent()
      state = :sys.get_state(pid)
      assert state.spawned_child_teams == []
    end

    test "receiving :child_team_spawned message adds team_id to spawned_child_teams" do
      %{pid: pid} = start_agent()

      send(pid, {:child_team_spawned, "team-abc"})
      # allow handle_info to process
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert "team-abc" in state.spawned_child_teams
    end

    test "receiving :child_team_spawned with duplicate team_id is a no-op" do
      %{pid: pid} = start_agent()

      send(pid, {:child_team_spawned, "team-abc"})
      send(pid, {:child_team_spawned, "team-abc"})
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert Enum.count(state.spawned_child_teams, &(&1 == "team-abc")) == 1
    end
  end

  describe "terminate/2 child team dissolution" do
    test "terminate/2 with no child teams completes without error" do
      %{pid: pid} = start_agent()
      # Should stop cleanly with no child teams
      GenServer.stop(pid, :shutdown)
      refute Process.alive?(pid)
    end

    test "terminate/2 calls Manager.dissolve_team for each spawned child team" do
      %{pid: pid} = start_agent()

      # Create two real child teams via Manager so they exist in ETS
      {:ok, child_team_x} =
        Manager.create_team(name: "child-team-x-#{:erlang.unique_integer([:positive])}")

      {:ok, child_team_y} =
        Manager.create_team(name: "child-team-y-#{:erlang.unique_integer([:positive])}")

      # Inject child teams into agent state (simulating on_tool_execute having tracked them)
      send(pid, {:child_team_spawned, child_team_x})
      send(pid, {:child_team_spawned, child_team_y})
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert child_team_x in state.spawned_child_teams
      assert child_team_y in state.spawned_child_teams

      # Stop the agent — terminate/2 should dissolve the child teams
      GenServer.stop(pid, :shutdown)
      :timer.sleep(100)

      # After dissolution, get_team_meta should return :error
      assert Manager.get_team_meta(child_team_x) == :error
      assert Manager.get_team_meta(child_team_y) == :error
    end
  end
end
