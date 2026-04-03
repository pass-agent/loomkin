defmodule Loomkin.Teams.AgentStateMachineTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent

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

  # Build a minimal Task struct with a known ref for injecting into loop_task state.
  # Task enforces :mfa so we provide a no-op placeholder.
  defp fake_task(ref),
    do: struct!(Task, ref: ref, pid: self(), owner: self(), mfa: {Kernel, :send, []})

  describe "pause_queued field" do
    test "defaults to false in struct" do
      %{pid: pid} = start_agent()
      state = :sys.get_state(pid)
      assert state.pause_queued == false
    end
  end

  describe "request_pause guards" do
    test "sets pause_requested when status is :working" do
      %{pid: pid} = start_agent()
      :sys.replace_state(pid, fn s -> %{s | status: :working} end)

      Agent.request_pause(pid)
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert state.pause_requested == true
      assert state.pause_queued == false
    end

    test "queues pause when status is :waiting_permission" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{s | status: :waiting_permission, pending_permission: %{some: :data}}
      end)

      Agent.request_pause(pid)
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert state.pause_queued == true
      assert state.pause_requested == false
    end

    test "no-op when status is :idle" do
      %{pid: pid} = start_agent()
      state_before = :sys.get_state(pid)
      assert state_before.status == :idle

      Agent.request_pause(pid)
      :timer.sleep(50)

      state_after = :sys.get_state(pid)
      assert state_after.pause_requested == false
      assert state_after.pause_queued == false
    end

    test "queues pause when status is :approval_pending" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{s | status: :approval_pending}
      end)

      Agent.request_pause(pid)
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert state.pause_queued == true
      assert state.pause_requested == false
    end
  end

  describe "permission_response with pause_queued" do
    test "auto-transitions to :paused when pause_queued is true" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :waiting_permission,
            pause_queued: true,
            pending_permission: %{
              tool_name: "file_read",
              tool_path: "/tmp/test",
              pending_data: %{
                tool_module: Loomkin.Tools.FileRead,
                tool_args: %{},
                context: %{project_path: "/tmp"}
              }
            }
        }
      end)

      GenServer.cast(pid, {:permission_response, "allow_once", "file_read", "/tmp/test"})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :paused
      assert state.pause_queued == false
      assert state.pending_permission == nil
      assert state.paused_state != nil
      assert state.paused_state.reason == :user_requested
    end

    test "preserves denial context in paused_state when denied with pause_queued" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :waiting_permission,
            pause_queued: true,
            pending_permission: %{
              tool_name: "shell",
              tool_path: "/usr/bin/rm",
              pending_data: %{
                tool_module: Loomkin.Tools.Shell,
                tool_args: %{},
                context: %{project_path: "/tmp"}
              }
            }
        }
      end)

      GenServer.cast(pid, {:permission_response, "deny", "shell", "/usr/bin/rm"})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :paused
      assert state.pause_queued == false

      assert state.paused_state.cancelled_permission == %{
               denied_tool: "shell",
               denied_path: "/usr/bin/rm"
             }
    end

    test "resumes work normally when pause_queued is false" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :waiting_permission,
            pause_queued: false,
            pending_permission: %{
              tool_name: "file_read",
              tool_path: "/tmp/test",
              pending_data: %{
                tool_module: Loomkin.Tools.FileRead,
                tool_args: %{},
                context: %{project_path: "/tmp"}
              }
            }
        }
      end)

      GenServer.cast(pid, {:permission_response, "allow_once", "file_read", "/tmp/test"})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      # Should NOT be paused -- normal flow continues
      assert state.pending_permission == nil
      assert state.pause_queued == false
      refute state.status == :paused
    end
  end

  describe "set_status_and_broadcast guards" do
    test "rejects direct transition from :waiting_permission to :paused" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{s | status: :waiting_permission, pending_permission: %{some: :data}}
      end)

      Agent.request_pause(pid)
      :timer.sleep(50)

      state = :sys.get_state(pid)
      # Must still be :waiting_permission, not :paused
      assert state.status == :waiting_permission
      assert state.pause_queued == true
    end
  end

  # Issue #19: pause_queued → :paused after approval_pending gate resolves.
  # The spawn gate tool task returns {:loop_ok, ...} or {:loop_error, ...} when
  # the gate resolves. maybe_apply_queued_pause/2 checks pause_queued at that
  # point and overrides :idle → :paused if needed.
  describe "pause_queued after approval_pending resolves" do
    test "agent transitions to :paused instead of :idle when pause_queued is true at loop_ok" do
      %{pid: pid} = start_agent()

      fake_ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :approval_pending,
            pause_queued: true,
            loop_task: {fake_task(fake_ref), nil}
        }
      end)

      # Send the fake loop_ok message — simulates spawn gate resolving and loop completing.
      send(pid, {fake_ref, {:loop_ok, "done", [], %{}}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :paused
      assert state.pause_queued == false
      assert state.paused_state != nil
      assert state.paused_state.reason == :user_requested
    end

    test "agent transitions to :paused instead of :idle when pause_queued is true at loop_error" do
      %{pid: pid} = start_agent()

      fake_ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :approval_pending,
            pause_queued: true,
            loop_task: {fake_task(fake_ref), nil}
        }
      end)

      send(pid, {fake_ref, {:loop_error, :some_error, []}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :paused
      assert state.pause_queued == false
      assert state.paused_state != nil
      assert state.paused_state.reason == :user_requested
    end

    test "agent goes to :idle normally when pause_queued is false at loop_ok" do
      %{pid: pid} = start_agent()

      fake_ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :approval_pending,
            pause_queued: false,
            loop_task: {fake_task(fake_ref), nil}
        }
      end)

      send(pid, {fake_ref, {:loop_ok, "done", [], %{}}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.pause_queued == false
      assert state.paused_state == nil
    end
  end

  # Issue #20: force_pause/1 must return {:error, :not_waiting_permission} for
  # any state other than :waiting_permission — documenting intentional behavior.
  describe "force_pause: non-waiting_permission states" do
    test "returns {:error, :not_waiting_permission} when agent is :idle" do
      %{pid: pid} = start_agent()

      state = :sys.get_state(pid)
      assert state.status == :idle

      result = Agent.force_pause(pid)
      assert result == {:error, :not_waiting_permission}
    end

    test "returns {:error, :not_waiting_permission} when agent is :working" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s -> %{s | status: :working} end)

      result = Agent.force_pause(pid)
      assert result == {:error, :not_waiting_permission}
    end

    test "returns {:error, :not_waiting_permission} when agent is :paused" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :paused,
            paused_state: %{messages: [], iteration: nil, reason: :user_requested}
        }
      end)

      result = Agent.force_pause(pid)
      assert result == {:error, :not_waiting_permission}
    end
  end
end
