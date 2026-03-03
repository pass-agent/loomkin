defmodule Loomkin.Teams.AgentProjectPathTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Agent, Manager}

  defp create_team(opts) do
    name = Keyword.get(opts, :name, "test-team")
    project_path = Keyword.get(opts, :project_path, "/tmp/project-a")
    {:ok, team_id} = Manager.create_team(name: name, project_path: project_path)
    team_id
  end

  defp start_agent_in_team(team_id, overrides \\ []) do
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)
    project_path = Manager.get_team_project_path(team_id)

    opts =
      [team_id: team_id, name: name, role: role, project_path: project_path]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name}
  end

  describe "resolve_project_path/2" do
    test "returns team ETS path when available" do
      team_id = create_team(project_path: "/tmp/project-a")

      assert Agent.resolve_project_path(team_id, "/fallback") == "/tmp/project-a"
    end

    test "returns fallback when team ETS has no path" do
      assert Agent.resolve_project_path("nonexistent-team-id", "/fallback") == "/fallback"
    end

    test "returns updated path after Manager.update_project_path" do
      team_id = create_team(project_path: "/tmp/project-a")

      assert Agent.resolve_project_path(team_id, "/fallback") == "/tmp/project-a"

      Manager.update_project_path(team_id, "/tmp/project-b")

      assert Agent.resolve_project_path(team_id, "/fallback") == "/tmp/project-b"
    end
  end

  describe "get_team_project_path/1 (now public)" do
    test "returns the project path from team ETS" do
      team_id = create_team(project_path: "/tmp/my-project")

      assert Manager.get_team_project_path(team_id) == "/tmp/my-project"
    end

    test "returns nil for non-existent team" do
      assert Manager.get_team_project_path("does-not-exist") == nil
    end
  end

  describe "agent state updates on project path change" do
    test "handle_cast :update_project_path updates agent state" do
      team_id = create_team(project_path: "/tmp/project-a")
      %{pid: pid} = start_agent_in_team(team_id)

      state_before = :sys.get_state(pid)
      assert state_before.project_path == "/tmp/project-a"

      GenServer.cast(pid, {:update_project_path, "/tmp/project-b"})
      Process.sleep(50)

      state_after = :sys.get_state(pid)
      assert state_after.project_path == "/tmp/project-b"
    end
  end

  describe "Manager.cancel_all_loops/1" do
    test "cancels active loops across team agents" do
      team_id = create_team(project_path: "/tmp/test")
      %{pid: pid} = start_agent_in_team(team_id)

      # Simulate an active loop task
      :sys.replace_state(pid, fn state ->
        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            Process.sleep(:infinity)
          end)

        %{state | loop_task: {task, nil}, status: :working}
      end)

      state = :sys.get_state(pid)
      assert state.loop_task != nil

      Manager.cancel_all_loops(team_id)

      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
    end
  end

  describe "AgentLoop.current_project_path/1" do
    test "returns static path when no resolver is provided" do
      config = %{project_path: "/static/path", project_path_resolver: nil}
      assert Loomkin.AgentLoop.current_project_path(config) == "/static/path"
    end

    test "returns resolver result when resolver is provided" do
      config = %{
        project_path: "/static/path",
        project_path_resolver: fn -> "/dynamic/path" end
      }

      assert Loomkin.AgentLoop.current_project_path(config) == "/dynamic/path"
    end

    test "falls back to static path when resolver returns nil" do
      config = %{
        project_path: "/static/path",
        project_path_resolver: fn -> nil end
      }

      assert Loomkin.AgentLoop.current_project_path(config) == "/static/path"
    end

    test "resolver tracks ETS changes dynamically" do
      team_id = create_team(project_path: "/tmp/original")

      resolver = fn -> Manager.get_team_project_path(team_id) end
      config = %{project_path: "/tmp/fallback", project_path_resolver: resolver}

      assert Loomkin.AgentLoop.current_project_path(config) == "/tmp/original"

      Manager.update_project_path(team_id, "/tmp/switched")

      assert Loomkin.AgentLoop.current_project_path(config) == "/tmp/switched"
    end
  end
end
