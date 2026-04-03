defmodule Loomkin.Teams.AgentQueueTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.QueuedMessage

  defp unique_team_id do
    "test-queue-#{:erlang.unique_integer([:positive])}"
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
    :sys.replace_state(pid, fn state ->
      task =
        Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      %{state | loop_task: {task, nil}, status: :working}
    end)
  end

  describe "enqueue/3" do
    test "adds a QueuedMessage to pending_updates" do
      %{pid: pid} = start_agent()

      assert {:ok, id} = Agent.enqueue(pid, "do something")
      assert is_binary(id)

      state = :sys.get_state(pid)
      assert length(state.pending_updates) == 1
      [qm] = state.pending_updates
      assert %QueuedMessage{} = qm
      assert qm.id == id
      assert qm.content == {:inject_system_message, "do something"}
      assert qm.source == :user
      assert qm.priority == :normal
    end

    test "high priority goes to priority_queue" do
      %{pid: pid} = start_agent()

      {:ok, _id} = Agent.enqueue(pid, "urgent stuff", priority: :high)

      state = :sys.get_state(pid)
      assert length(state.priority_queue) == 1
      assert state.pending_updates == []
    end

    test "works even when agent is idle" do
      %{pid: pid} = start_agent()

      assert :idle = Agent.get_status(pid)
      assert {:ok, _id} = Agent.enqueue(pid, "queued while idle")
    end
  end

  describe "list_queue/1" do
    test "returns empty list when no queued messages" do
      %{pid: pid} = start_agent()
      assert [] = Agent.list_queue(pid)
    end

    test "returns merged priority + pending queues" do
      %{pid: pid} = start_agent()

      {:ok, _} = Agent.enqueue(pid, "high msg", priority: :high)
      {:ok, _} = Agent.enqueue(pid, "normal msg")

      queue = Agent.list_queue(pid)
      assert length(queue) == 2

      # Priority comes first
      [first, second] = queue
      assert first.priority == :high
      assert second.priority == :normal
    end
  end

  describe "edit_queued/3" do
    test "modifies content of a queued message by ID" do
      %{pid: pid} = start_agent()

      {:ok, id} = Agent.enqueue(pid, "original text")
      assert :ok = Agent.edit_queued(pid, id, {:inject_system_message, "edited text"})

      [qm] = Agent.list_queue(pid)
      assert qm.content == {:inject_system_message, "edited text"}
      assert qm.status == :editing
    end

    test "returns error for nonexistent ID" do
      %{pid: pid} = start_agent()
      assert {:error, :not_found} = Agent.edit_queued(pid, "qm_nonexistent", "new")
    end
  end

  describe "reorder_queue/3" do
    test "changes order of pending queue" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "first")
      {:ok, id2} = Agent.enqueue(pid, "second")
      {:ok, id3} = Agent.enqueue(pid, "third")

      assert :ok = Agent.reorder_queue(pid, :pending, [id3, id1, id2])

      state = :sys.get_state(pid)
      ids = Enum.map(state.pending_updates, & &1.id)
      assert ids == [id3, id1, id2]
    end

    test "preserves messages not in ordered_ids" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "first")
      {:ok, id2} = Agent.enqueue(pid, "second")
      {:ok, _id3} = Agent.enqueue(pid, "third")

      # Only specify 2 of 3 IDs
      assert :ok = Agent.reorder_queue(pid, :pending, [id2, id1])

      state = :sys.get_state(pid)
      assert length(state.pending_updates) == 3
    end
  end

  describe "squash_queued/3" do
    test "merges multiple messages into one" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "message one")
      {:ok, id2} = Agent.enqueue(pid, "message two")

      assert {:ok, squashed_id} = Agent.squash_queued(pid, [id1, id2])
      assert is_binary(squashed_id)

      queue = Agent.list_queue(pid)
      assert length(queue) == 1
      [squashed] = queue
      assert squashed.id == squashed_id
      assert squashed.status == :squashed
      assert squashed.metadata[:squashed_from] == [id1, id2]
    end

    test "returns error when fewer than 2 messages match" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "only one")
      assert {:error, :not_enough_messages} = Agent.squash_queued(pid, [id1])
    end

    test "accepts custom content" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "msg one")
      {:ok, id2} = Agent.enqueue(pid, "msg two")

      {:ok, _} = Agent.squash_queued(pid, [id1, id2], content: "combined message")

      [squashed] = Agent.list_queue(pid)
      assert squashed.content == {:inject_system_message, "combined message"}
    end

    test "uses highest priority from matched messages" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "normal msg")
      {:ok, id2} = Agent.enqueue(pid, "high msg", priority: :high)

      {:ok, _} = Agent.squash_queued(pid, [id1, id2])

      state = :sys.get_state(pid)
      # Squashed to priority_queue because highest is :high
      assert length(state.priority_queue) == 1
      assert state.pending_updates == []
    end
  end

  describe "delete_queued/2" do
    test "removes a message by ID" do
      %{pid: pid} = start_agent()

      {:ok, id1} = Agent.enqueue(pid, "keep me")
      {:ok, id2} = Agent.enqueue(pid, "delete me")

      assert :ok = Agent.delete_queued(pid, id2)

      queue = Agent.list_queue(pid)
      assert length(queue) == 1
      assert hd(queue).id == id1
    end

    test "returns error for nonexistent ID" do
      %{pid: pid} = start_agent()
      assert {:error, :not_found} = Agent.delete_queued(pid, "qm_nonexistent")
    end
  end

  describe "inject_guidance/2" do
    test "adds guidance to priority_queue" do
      %{pid: pid} = start_agent()

      assert :ok = Agent.inject_guidance(pid, "focus on tests")

      state = :sys.get_state(pid)
      assert length(state.priority_queue) == 1
      [qm] = state.priority_queue
      assert qm.content == {:inject_system_message, "[User Guidance]: focus on tests"}
      assert qm.priority == :high
      assert qm.source == :user
      assert qm.metadata == %{type: :guidance}
    end
  end

  describe "priority routing with QueuedMessage wrapping" do
    test "high priority messages are wrapped in QueuedMessage during active loop" do
      %{pid: pid} = start_agent()
      simulate_active_loop(pid)

      # task_assigned is classified as :high by PriorityRouter
      send(pid, {:task_assigned, "t1", "other-agent"})
      # Allow GenServer to process
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.priority_queue) == 1
      [qm] = state.priority_queue
      assert %QueuedMessage{} = qm
      assert qm.content == {:task_assigned, "t1", "other-agent"}
      assert qm.priority == :high
    end

    test "normal priority messages are wrapped in QueuedMessage during active loop" do
      %{pid: pid} = start_agent()
      simulate_active_loop(pid)

      # context_update is classified as :normal by PriorityRouter
      send(pid, {:context_update, "peer", %{data: "test"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      # Find our specific message (other system messages may also be queued)
      matching =
        Enum.filter(state.pending_updates, fn qm ->
          qm.content == {:context_update, "peer", %{data: "test"}}
        end)

      assert length(matching) == 1
      [qm] = matching
      assert %QueuedMessage{} = qm
      assert qm.priority == :normal
    end
  end

  describe "drain_queues with QueuedMessage" do
    test "drain_queues unwraps QueuedMessages correctly" do
      %{pid: pid} = start_agent()

      # Manually insert QueuedMessages into queues
      qm1 = QueuedMessage.new({:inject_system_message, "priority msg"}, priority: :high)
      qm2 = QueuedMessage.new({:context_update, "peer", %{}}, priority: :normal)

      :sys.replace_state(pid, fn state ->
        %{state | priority_queue: [qm1], pending_updates: [qm2]}
      end)

      # Trigger drain_queues by simulating a loop completion
      # We do this by sending :sys.replace_state to clear loop_task first,
      # then directly calling drain on the state
      state = :sys.get_state(pid)
      assert length(state.priority_queue) == 1
      assert length(state.pending_updates) == 1

      # Trigger drain by sending a fake loop_ok result
      # Set up a fake loop_task first
      :sys.replace_state(pid, fn state ->
        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            {:loop_ok, "done", [], %{}}
          end)

        %{state | loop_task: {task, nil}, priority_queue: [qm1], pending_updates: [qm2]}
      end)

      # Wait for the task result to be processed
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.priority_queue == []
      assert state.pending_updates == []
    end
  end

  describe "broadcast_queue_update" do
    test "fires signal on enqueue" do
      # Subscribe to agent.queue.updated signals
      Loomkin.Signals.subscribe("agent.queue.updated")

      %{pid: pid, name: name} = start_agent()

      {:ok, _id} = Agent.enqueue(pid, "test msg")

      assert_receive {:signal, %Jido.Signal{type: "agent.queue.updated"} = sig}, 1000
      assert sig.data.agent_name == to_string(name)
    end

    test "fires signal on delete" do
      Loomkin.Signals.subscribe("agent.queue.updated")

      %{pid: pid} = start_agent()

      {:ok, id} = Agent.enqueue(pid, "to delete")
      # Flush the enqueue signal
      assert_receive {:signal, %Jido.Signal{type: "agent.queue.updated"}}, 1000

      Agent.delete_queued(pid, id)
      assert_receive {:signal, %Jido.Signal{type: "agent.queue.updated"} = sig}, 1000
      assert sig.data.queue == []
    end
  end
end
