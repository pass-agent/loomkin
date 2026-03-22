defmodule Loomkin.Teams.AgentHealingTest do
  @moduledoc """
  Tests for agent suspension and wake protocol (epic 14.2).
  Verifies that agents correctly transition to :suspended_healing,
  freeze state, publish signals, queue messages, and wake on command.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.QueuedMessage

  setup do
    prev = Application.get_env(:loomkin, :healing_ephemeral_agent)
    Application.put_env(:loomkin, :healing_ephemeral_agent, Loomkin.Healing.EphemeralAgentStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:loomkin, :healing_ephemeral_agent, prev),
        else: Application.delete_env(:loomkin, :healing_ephemeral_agent)
    end)

    :ok
  end

  defp unique_team_id do
    "test-healing-#{:erlang.unique_integer([:positive])}"
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

  defp suspend_agent(pid) do
    :sys.replace_state(pid, fn state ->
      frozen_state = %{
        messages: state.messages,
        task: state.task
      }

      %{
        state
        | status: :suspended_healing,
          frozen_state: frozen_state,
          loop_task: nil,
          failure_count: 3
      }
    end)
  end

  defp suspend_agent_with_task(pid) do
    :sys.replace_state(pid, fn state ->
      task = %{id: "task-#{:erlang.unique_integer([:positive])}", title: "test task"}

      frozen_state = %{
        messages: [%{role: :user, content: "do something"}],
        task: task
      }

      %{
        state
        | status: :suspended_healing,
          frozen_state: frozen_state,
          task: task,
          messages: [%{role: :user, content: "do something"}],
          loop_task: nil,
          failure_count: 3,
          cost_usd: 0.5,
          tokens_used: 1000
      }
    end)
  end

  # -- Suspension state --------------------------------------------------------

  describe "suspension state" do
    test "agent transitions to :suspended_healing via loop_healing_needed" do
      %{pid: pid} = start_agent()

      classification = %{
        category: :compile_error,
        severity: :medium,
        healable: true,
        error_context: %{file_path: "lib/foo.ex", line: 10},
        suggested_approach: "Check imports"
      }

      # Simulate the loop returning a healing_needed result
      # We use :sys.replace_state to set up a fake loop_task, then send the result
      fake_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        fake_task = %Task{ref: fake_ref, pid: self(), owner: self(), mfa: {__MODULE__, :test, []}}
        %{state | loop_task: {fake_task, nil}, status: :working}
      end)

      send(
        pid,
        {fake_ref, {:loop_healing_needed, classification, [%{role: :user, content: "hi"}]}}
      )

      # Flush the DOWN monitor message that GenServer expects
      send(pid, {:DOWN, fake_ref, :process, self(), :normal})

      # Allow message processing
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :suspended_healing
      assert state.frozen_state != nil
      assert state.frozen_state.messages == [%{role: :user, content: "hi"}]
      assert state.loop_task == nil
    end

    test "frozen state preserves messages and task" do
      %{pid: pid} = start_agent()
      suspend_agent_with_task(pid)

      state = :sys.get_state(pid)
      assert state.status == :suspended_healing
      assert state.frozen_state.messages == [%{role: :user, content: "do something"}]
      assert state.frozen_state.task.title == "test task"
    end
  end

  # -- Task assignment during suspension ---------------------------------------

  describe "task assignment during suspension" do
    test "queues task assignments while suspended" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      task = %{id: "queued-task-1", title: "new task"}
      Agent.assign_task(pid, task)

      # Allow cast to process
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.healing_queue) == 1
      [qm] = state.healing_queue
      assert %QueuedMessage{} = qm
    end

    test "queues multiple tasks during suspension" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      Agent.assign_task(pid, %{id: "t1", title: "task 1"})
      Agent.assign_task(pid, %{id: "t2", title: "task 2"})

      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.healing_queue) == 2
    end
  end

  # -- Wake protocol -----------------------------------------------------------

  describe "wake_from_healing/2" do
    test "wakes agent from :suspended_healing to :idle" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      healing_summary = %{
        description: "Fixed missing import",
        root_cause: "Missing alias for Foo.Bar",
        fix_description: "Added alias Foo.Bar to module"
      }

      Agent.wake_from_healing(pid, healing_summary)

      # Allow cast to process
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.frozen_state == nil
      assert state.failure_count == 0
    end

    test "injects summary message into conversation" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      healing_summary = %{
        description: "Resolved compile error",
        root_cause: "Missing import",
        fix_description: "Added import statement"
      }

      Agent.wake_from_healing(pid, healing_summary)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      last_message = List.last(state.messages)
      assert last_message.role == :system
      assert last_message.content =~ "Healing complete"
      assert last_message.content =~ "Missing import"
      assert last_message.content =~ "Added import statement"
    end

    test "resets failure_count to 0 after wake" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      state_before = :sys.get_state(pid)
      assert state_before.failure_count == 3

      Agent.wake_from_healing(pid, %{description: "fixed"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.failure_count == 0
    end

    test "no-op when agent is not suspended" do
      %{pid: pid} = start_agent()

      state_before = :sys.get_state(pid)
      assert state_before.status == :idle

      Agent.wake_from_healing(pid, %{description: "fixed"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.frozen_state == nil
    end

    test "drains healing queue on wake" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      Agent.assign_task(pid, %{id: "queued-task", title: "queued"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.healing_queue) == 1

      Agent.wake_from_healing(pid, %{description: "fixed"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.healing_queue == []
    end
  end

  # -- Broadcast during suspension ---------------------------------------------

  describe "inject_broadcast during suspension" do
    test "queues broadcast into frozen state messages" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      :ok = Agent.inject_broadcast(pid, "team update: new context")

      state = :sys.get_state(pid)
      assert state.status == :suspended_healing

      last_frozen_msg = List.last(state.frozen_state.messages)
      assert last_frozen_msg.role == :user
      assert last_frozen_msg.content == "team update: new context"
    end
  end

  # -- Signal types ------------------------------------------------------------

  describe "healing signal types" do
    test "HealingRequested signal can be created" do
      signal =
        Loomkin.Signals.Agent.HealingRequested.new!(%{
          agent_name: "coder-1",
          team_id: "team-abc",
          classification: %{category: :compile_error, severity: :medium},
          error_context: %{file_path: "lib/foo.ex"}
        })

      assert signal.type == "agent.healing.requested"
      assert signal.data.agent_name == "coder-1"
      assert signal.data.classification.category == :compile_error
    end

    test "HealingComplete signal can be created" do
      signal =
        Loomkin.Signals.Agent.HealingComplete.new!(%{
          agent_name: "coder-1",
          team_id: "team-abc",
          healing_summary: %{description: "Fixed", root_cause: "Bug", fix_description: "Patch"}
        })

      assert signal.type == "agent.healing.complete"
      assert signal.data.healing_summary.description == "Fixed"
    end
  end

  # -- Error classification integration in agent loop --------------------------

  describe "error classification in run_loop_with_escalation" do
    test "ErrorClassifier.classify/2 correctly identifies compile errors" do
      alias Loomkin.Healing.ErrorClassifier

      result =
        ErrorClassifier.classify("** (CompileError) lib/foo.ex:10: undefined function bar/1")

      assert result.category == :compile_error
      assert result.healable == true
    end

    test "ErrorClassifier.should_heal?/2 respects failure threshold" do
      alias Loomkin.Healing.ErrorClassifier

      classification = %{category: :compile_error, severity: :medium, healable: true}

      refute ErrorClassifier.should_heal?(classification, %{failure_count: 0})
      assert ErrorClassifier.should_heal?(classification, %{failure_count: 1})
    end
  end
end
