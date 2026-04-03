defmodule Loomkin.Teams.AgentScopeGateTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent

  defp unique_team_id do
    "test-scope-#{:erlang.unique_integer([:positive])}"
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

  describe "scope tier on task assignment" do
    test "assigns :quick tier for fix tasks" do
      %{pid: pid} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the typo"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.scope_tier == :quick
      assert state.files_touched == MapSet.new()
    end

    test "assigns :session tier for add/create tasks" do
      %{pid: pid} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t2", title: "add a new webhook endpoint"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.scope_tier == :session
    end

    test "assigns :campaign tier for refactor tasks" do
      %{pid: pid} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t3", title: "refactor the auth system"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.scope_tier == :campaign
    end
  end

  describe "file tracking from tool_executing signals" do
    test "tracks file paths from file_write tool signals" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      sig =
        Loomkin.Signals.Agent.ToolExecuting.new!(
          %{agent_name: to_string(name), team_id: "ignored"},
          subject: "payload"
        )
        |> Map.put(:data, %{
          agent_name: to_string(name),
          payload: %{tool_name: "file_write", tool_target: "/tmp/foo.ex"}
        })

      send(pid, sig)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.files_touched, "/tmp/foo.ex")
    end

    test "tracks file paths from file_edit tool signals" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      sig =
        Loomkin.Signals.Agent.ToolExecuting.new!(
          %{agent_name: to_string(name), team_id: "ignored"},
          subject: "payload"
        )
        |> Map.put(:data, %{
          agent_name: to_string(name),
          payload: %{tool_name: "file_edit", tool_target: "/tmp/bar.ex"}
        })

      send(pid, sig)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.files_touched, "/tmp/bar.ex")
    end

    test "ignores file signals from other agents" do
      %{pid: pid} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      sig =
        Loomkin.Signals.Agent.ToolExecuting.new!(
          %{agent_name: "other-agent", team_id: "ignored"},
          subject: "payload"
        )
        |> Map.put(:data, %{
          agent_name: "other-agent",
          payload: %{tool_name: "file_write", tool_target: "/tmp/other.ex"}
        })

      send(pid, sig)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert MapSet.size(state.files_touched) == 0
    end
  end

  describe "checkpoint scope gate enforcement" do
    test "checkpoint returns :continue when within envelope" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      # Touch 2 files — within :quick envelope of 3
      for path <- ["/tmp/a.ex", "/tmp/b.ex"] do
        sig =
          Loomkin.Signals.Agent.ToolExecuting.new!(
            %{agent_name: to_string(name), team_id: "ignored"},
            subject: "payload"
          )
          |> Map.put(:data, %{
            agent_name: to_string(name),
            payload: %{tool_name: "file_write", tool_target: path}
          })

        send(pid, sig)
      end

      _ = :sys.get_state(pid)
      assert GenServer.call(pid, {:checkpoint, %{}}) == :continue
    end

    test "checkpoint pauses with scope gate when files exceed quick envelope" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      # Touch 4 files — exceeds :quick envelope of 3
      for i <- 1..4 do
        sig =
          Loomkin.Signals.Agent.ToolExecuting.new!(
            %{agent_name: to_string(name), team_id: "ignored"},
            subject: "payload"
          )
          |> Map.put(:data, %{
            agent_name: to_string(name),
            payload: %{tool_name: "file_write", tool_target: "/tmp/file_#{i}.ex"}
          })

        send(pid, sig)
      end

      _ = :sys.get_state(pid)

      result = GenServer.call(pid, {:checkpoint, %{}})
      assert {:pause, {:scope_gate, details}} = result
      assert details.tier == :quick
      assert details.trigger == :files
      assert details.current == 4
      assert details.limit == 3
    end

    test "checkpoint pauses when cost exceeds quick envelope" do
      %{pid: pid} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      # Set per-task cost above :quick envelope of $0.50
      :sys.replace_state(pid, fn state -> %{state | task_cost_usd: 0.75} end)

      result = GenServer.call(pid, {:checkpoint, %{}})
      assert {:pause, {:scope_gate, details}} = result
      assert details.tier == :quick
      assert details.trigger == :cost
    end

    test "campaign tier allows many files without pausing" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "refactor the auth system"}})
      _ = :sys.get_state(pid)

      # Touch 20 files — within :campaign envelope of 50
      for i <- 1..20 do
        sig =
          Loomkin.Signals.Agent.ToolExecuting.new!(
            %{agent_name: to_string(name), team_id: "ignored"},
            subject: "payload"
          )
          |> Map.put(:data, %{
            agent_name: to_string(name),
            payload: %{tool_name: "file_write", tool_target: "/tmp/file_#{i}.ex"}
          })

        send(pid, sig)
      end

      _ = :sys.get_state(pid)
      assert GenServer.call(pid, {:checkpoint, %{}}) == :continue
    end

    test "checkpoint continues when no scope tier is set" do
      %{pid: pid} = start_agent()
      # No task assigned, scope_tier is nil
      assert GenServer.call(pid, {:checkpoint, %{}}) == :continue
    end

    test "files_touched resets on new task assignment" do
      %{pid: pid, name: name} = start_agent()
      GenServer.cast(pid, {:assign_task, %{id: "t1", title: "fix the bug"}})
      _ = :sys.get_state(pid)

      sig =
        Loomkin.Signals.Agent.ToolExecuting.new!(
          %{agent_name: to_string(name), team_id: "ignored"},
          subject: "payload"
        )
        |> Map.put(:data, %{
          agent_name: to_string(name),
          payload: %{tool_name: "file_write", tool_target: "/tmp/foo.ex"}
        })

      send(pid, sig)
      _ = :sys.get_state(pid)

      assert MapSet.size(:sys.get_state(pid).files_touched) == 1

      # Assign new task — files_touched should reset
      GenServer.cast(pid, {:assign_task, %{id: "t2", title: "add a new feature"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert MapSet.size(state.files_touched) == 0
      assert state.scope_tier == :session
    end
  end
end
