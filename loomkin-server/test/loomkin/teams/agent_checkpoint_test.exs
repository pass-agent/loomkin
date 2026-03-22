defmodule Loomkin.Teams.AgentCheckpointTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent

  defp unique_team_id do
    "test-checkpoint-#{:erlang.unique_integer([:positive])}"
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

  defp simulate_active_loop(pid) do
    new_state =
      :sys.replace_state(pid, fn state ->
        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            Process.sleep(:infinity)
          end)

        %{state | loop_task: {task, nil}, status: :working}
      end)

    {task, _from} = new_state.loop_task
    task
  end

  describe "pause_requested flag" do
    test "defaults to false" do
      %{pid: pid} = start_agent()
      state = :sys.get_state(pid)
      assert state.pause_requested == false
      assert state.paused_state == nil
    end

    test "request_pause sets the flag" do
      %{pid: pid} = start_agent()
      # Agent must be :working for request_pause to set the flag (idle is a no-op)
      :sys.replace_state(pid, fn s -> %{s | status: :working} end)
      Agent.request_pause(pid)
      # Allow cast to process
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.pause_requested == true
    end
  end

  describe "checkpoint callback" do
    test "returns :continue when pause not requested" do
      %{pid: pid} = start_agent()
      checkpoint = %Loomkin.AgentLoop.Checkpoint{type: :post_llm, iteration: 0}
      assert :continue = GenServer.call(pid, {:checkpoint, checkpoint})
    end

    test "returns {:pause, :user_requested} when pause is requested" do
      %{pid: pid} = start_agent()
      # Agent must be :working for request_pause to set the flag (idle is a no-op)
      :sys.replace_state(pid, fn s -> %{s | status: :working} end)
      Agent.request_pause(pid)
      _ = :sys.get_state(pid)

      checkpoint = %Loomkin.AgentLoop.Checkpoint{type: :post_llm, iteration: 0}
      assert {:pause, :user_requested} = GenServer.call(pid, {:checkpoint, checkpoint})
    end
  end

  describe "paused status handling" do
    test "loop_paused result sets status to :paused and stores paused_state" do
      %{pid: pid} = start_agent()

      # Subscribe to agent status signals
      Loomkin.Signals.subscribe("agent.**")

      # Create a task from inside the GenServer so it owns the monitoring ref
      :sys.replace_state(pid, fn state ->
        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            {:loop_paused, :user_requested, [%{role: :user, content: "test"}], 3}
          end)

        %{state | loop_task: {task, nil}, status: :working}
      end)

      # Wait for the status broadcast with a timeout
      assert_receive {:signal, %Jido.Signal{type: "agent.status", data: %{status: :paused}}}, 500
      state = :sys.get_state(pid)

      assert state.status == :paused
      assert state.loop_task == nil
      assert state.pause_requested == false
      assert state.paused_state.iteration == 3
      assert state.paused_state.reason == :user_requested
      assert state.paused_state.messages == [%{role: :user, content: "test"}]
    end
  end

  describe "resume/2" do
    test "returns error when agent is not paused" do
      %{pid: pid} = start_agent()
      assert {:error, :not_paused} = Agent.resume(pid)
    end

    test "resumes a paused agent by re-launching the loop" do
      %{pid: pid} = start_agent()

      # Manually set paused state
      :sys.replace_state(pid, fn state ->
        paused_state = %{
          messages: [%{role: :user, content: "hello"}],
          iteration: 2,
          reason: :user_requested
        }

        %{
          state
          | status: :paused,
            paused_state: paused_state,
            messages: [%{role: :user, content: "hello"}]
        }
      end)

      state = :sys.get_state(pid)
      assert state.status == :paused

      # Resume will try to run AgentLoop.run which will fail (no real LLM),
      # but we can verify it transitions out of :paused
      result = Agent.resume(pid)
      assert result == :ok

      state = :sys.get_state(pid)
      assert state.status == :working
      assert state.paused_state == nil
      assert state.pause_requested == false
      assert state.loop_task != nil
    end
  end

  describe "steer/2" do
    test "injects guidance and resumes a paused agent" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn state ->
        paused_state = %{
          messages: [%{role: :user, content: "original task"}],
          iteration: 1,
          reason: :user_requested
        }

        %{
          state
          | status: :paused,
            paused_state: paused_state,
            messages: [%{role: :user, content: "original task"}]
        }
      end)

      result = Agent.steer(pid, "focus on tests instead")
      assert result == :ok

      state = :sys.get_state(pid)
      assert state.status == :working

      # Verify guidance was injected into messages
      guidance_msg =
        Enum.find(state.messages, fn m ->
          is_binary(m.content) && String.contains?(m.content, "focus on tests instead")
        end)

      assert guidance_msg != nil
      assert String.contains?(guidance_msg.content, "[User Guidance]")
    end
  end

  describe "cancel while paused" do
    test "cancel clears paused state and goes idle" do
      %{pid: pid} = start_agent()

      :sys.replace_state(pid, fn state ->
        paused_state = %{
          messages: [%{role: :user, content: "test"}],
          iteration: 1,
          reason: :user_requested
        }

        %{state | status: :paused, paused_state: paused_state}
      end)

      assert :ok = Agent.cancel(pid)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.paused_state == nil
      assert state.pause_requested == false
    end
  end

  describe "priority routing while paused" do
    test "messages are queued normally when loop is active" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      # Send a normal-priority message directly
      send(pid, {:context_update, "peer-1", %{info: "test"}})

      # Synchronize: get_state forces the GenServer to process all pending messages
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert length(state.pending_updates) > 0
    end
  end
end
