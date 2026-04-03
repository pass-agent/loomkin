defmodule Loomkin.Teams.AgentAsyncTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.QueuedMessage

  defp unique_team_id do
    "test-async-#{:erlang.unique_integer([:positive])}"
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
    # Spawn the task from within the GenServer process (via :sys.replace_state)
    # so that the GenServer owns the task and can call Task.shutdown on it.
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

  # Send a tuple message directly to the agent (bypassing PubSub/Bus).
  # The agent's handle_info still matches tuples for messages not yet
  # represented as signal types.
  defp send_to_agent(pid, msg) do
    send(pid, msg)
  end

  describe "async struct defaults" do
    test "new agent has nil loop_task and empty queues" do
      %{pid: pid} = start_agent()
      state = :sys.get_state(pid)

      assert state.loop_task == nil
      assert state.pending_updates == []
      assert state.priority_queue == []
    end
  end

  describe "cancel/1" do
    test "returns error when no task is running" do
      %{pid: pid} = start_agent()
      assert {:error, :no_task_running} = Agent.cancel(pid)
    end

    test "cancels a running loop task" do
      %{pid: pid} = start_agent()
      task = simulate_active_loop(pid)

      assert Process.alive?(task.pid)
      assert :ok = Agent.cancel(pid)

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
      refute Process.alive?(task.pid)
    end

    test "clears queues on cancel" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      # Queue some messages directly (agent no longer listens on PubSub)
      send_to_agent(pid, {:context_update, "peer-1", %{info: "test"}})
      send_to_agent(pid, {:tasks_unblocked, ["task-1"]})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.pending_updates) == 1
      assert length(state.priority_queue) == 1

      # Cancel should clear queues
      assert :ok = Agent.cancel(pid)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.pending_updates == []
      assert state.priority_queue == []
    end
  end

  describe "busy guard" do
    test "send_message returns {:error, :busy} when loop is active" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      assert {:error, :busy} = Agent.send_message(pid, "hello")
    end
  end

  describe "priority routing during active loop" do
    test "queues normal-priority messages in pending_updates" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      send_to_agent(pid, {:context_update, "peer-1", %{info: "test"}})

      Process.sleep(50)

      state = :sys.get_state(pid)

      matching =
        Enum.filter(state.pending_updates, fn qm ->
          qm.content == {:context_update, "peer-1", %{info: "test"}}
        end)

      assert length(matching) == 1
      assert %QueuedMessage{priority: :normal} = hd(matching)
      assert state.priority_queue == []
    end

    test "queues high-priority messages in priority_queue" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      send_to_agent(pid, {:tasks_unblocked, ["task-1"]})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.priority_queue) == 1
      assert state.pending_updates == []
    end

    test "ignores low-priority messages during loop" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      send_to_agent(pid, {:agent_status, "other-agent", :idle})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.pending_updates == []
      assert state.priority_queue == []
    end

    test "handles urgent abort_task by killing loop" do
      %{pid: pid} = start_agent()
      task = simulate_active_loop(pid)

      send_to_agent(pid, {:abort_task, "emergency"})

      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
      refute Process.alive?(task.pid)
    end

    test "handles urgent budget_exceeded by killing loop" do
      %{pid: pid} = start_agent()
      task = simulate_active_loop(pid)

      send_to_agent(pid, {:budget_exceeded, :team})

      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
      refute Process.alive?(task.pid)
    end

    test "handles urgent file_conflict by queuing injection (loop continues)" do
      %{pid: pid} = start_agent()
      task = simulate_active_loop(pid)

      send_to_agent(pid, {:file_conflict, %{file: "lib/foo.ex"}})

      Process.sleep(50)

      state = :sys.get_state(pid)
      # Loop should still be running
      assert state.loop_task != nil
      assert Process.alive?(task.pid)

      # Warning should be queued as inject_system_message (not in messages yet)
      assert Enum.any?(state.priority_queue, fn
               %QueuedMessage{content: {:inject_system_message, content}} ->
                 String.contains?(content, "File conflict")

               _ ->
                 false
             end)
    end

    test "file_conflict warning survives loop completion via drain" do
      %{pid: pid} = start_agent()

      ref = make_ref()
      fake_task = %Task{pid: self(), ref: ref, owner: self(), mfa: {__MODULE__, :fake, []}}

      # Simulate active loop with a queued file_conflict inject
      conflict_qm =
        QueuedMessage.new(
          {:inject_system_message, "[URGENT] File conflict detected: %{file: \"lib/foo.ex\"}"},
          priority: :urgent,
          source: :system
        )

      :sys.replace_state(pid, fn state ->
        %{
          state
          | loop_task: {fake_task, nil},
            status: :working,
            priority_queue: [conflict_qm]
        }
      end)

      # Complete the loop — messages get set from loop result, then drain replays inject
      send(pid, {ref, {:loop_ok, "done", [%{role: :assistant, content: "done"}], %{usage: %{}}}})

      # Wait for drain to complete — use :sys.get_state to synchronize with the GenServer
      # rather than a fixed sleep which is unreliable in CI.
      state =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          Process.sleep(20)
          s = :sys.get_state(pid)

          if Enum.any?(s.messages, &(Map.get(&1, :role) == :system)) do
            {:halt, s}
          else
            {:cont, nil}
          end
        end) || :sys.get_state(pid)

      assert Enum.any?(state.messages, fn msg ->
               msg.role == :system && String.contains?(msg.content, "File conflict")
             end)
    end

    test "multiple messages accumulate in correct queues" do
      %{pid: pid} = start_agent()
      _task = simulate_active_loop(pid)

      # Send multiple messages of different priorities directly
      send_to_agent(pid, {:context_update, "p1", %{}})
      send_to_agent(pid, {:tasks_unblocked, ["t1"]})
      send_to_agent(pid, {:peer_message, "lead", "hi"})
      send_to_agent(pid, {:agent_status, "x", :idle})

      Process.sleep(50)

      state = :sys.get_state(pid)
      # 2 normal messages (context_update, peer_message)
      assert length(state.pending_updates) == 2
      # 1 high message (tasks_unblocked)
      assert length(state.priority_queue) == 1
      # agent_status was ignored — not in either queue
    end
  end

  describe "idle path unchanged" do
    test "context_update works normally when idle" do
      %{pid: pid} = start_agent()

      send_to_agent(pid, {:context_update, "peer-1", %{info: "test data"}})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.context["peer-1"] == %{info: "test data"}
      assert state.pending_updates == []
    end

    test "peer_message works normally when idle" do
      %{pid: pid} = start_agent()

      send_to_agent(pid, {:peer_message, "lead", "do the thing"})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.messages) == 1
      assert hd(state.messages).content =~ "[Peer lead]"
    end
  end

  describe "loop result handling" do
    test "loop_ok result updates state and clears loop_task" do
      %{pid: pid} = start_agent()

      # Create a ref we control
      ref = make_ref()
      fake_task = %Task{pid: self(), ref: ref, owner: self(), mfa: {__MODULE__, :fake, []}}

      :sys.replace_state(pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working}
      end)

      # Send a fake loop result
      send(
        pid,
        {ref, {:loop_ok, "done!", [%{role: :assistant, content: "done!"}], %{usage: %{}}}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
      assert length(state.messages) == 1
      assert state.failure_count == 0
    end

    test "loop_error result sets idle and clears loop_task" do
      %{pid: pid} = start_agent()

      ref = make_ref()
      fake_task = %Task{pid: self(), ref: ref, owner: self(), mfa: {__MODULE__, :fake, []}}

      :sys.replace_state(pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working}
      end)

      send(pid, {ref, {:loop_error, :timeout, []}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :idle
    end

    test "DOWN message handles task crash" do
      %{pid: pid} = start_agent()

      ref = make_ref()
      fake_task = %Task{pid: self(), ref: ref, owner: self(), mfa: {__MODULE__, :fake, []}}

      :sys.replace_state(pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working}
      end)

      send(pid, {:DOWN, ref, :process, self(), :killed})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.loop_task == nil
      assert state.status == :error
    end

    test "queued messages are drained after loop completes" do
      %{pid: pid} = start_agent()

      ref = make_ref()
      fake_task = %Task{pid: self(), ref: ref, owner: self(), mfa: {__MODULE__, :fake, []}}

      pending_qm =
        QueuedMessage.new({:context_update, "peer-1", %{v: 1}},
          priority: :normal,
          source: :system
        )

      priority_qm =
        QueuedMessage.new({:tasks_unblocked, ["t1"]}, priority: :high, source: :system)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | loop_task: {fake_task, nil},
            status: :working,
            pending_updates: [pending_qm],
            priority_queue: [priority_qm]
        }
      end)

      # Complete the loop — should drain queues
      send(pid, {ref, {:loop_ok, "done", [%{role: :assistant, content: "done"}], %{usage: %{}}}})

      # Wait for drain to complete — poll until queues are empty AND context is updated.
      # Queues empty first (messages move to mailbox), then handle_info processes them.
      state =
        Enum.reduce_while(1..30, nil, fn _, _ ->
          Process.sleep(20)
          s = :sys.get_state(pid)

          if s.pending_updates == [] and s.priority_queue == [] and s.context["peer-1"] != nil do
            {:halt, s}
          else
            {:cont, nil}
          end
        end) || :sys.get_state(pid)

      # Queues should be drained
      assert state.pending_updates == []
      assert state.priority_queue == []

      # Drained messages should have been processed
      assert state.context["peer-1"] == %{v: 1}
    end
  end
end
