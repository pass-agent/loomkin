defmodule Loomkin.Healing.IntegrationTest do
  @moduledoc """
  Integration tests for the full self-healing lifecycle.
  Exercises: request → diagnose → fix → wake, retry paths, timeouts,
  concurrent sessions, cancellation, double-wake, and crash-during-healing.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Healing.ErrorClassifier
  alias Loomkin.Healing.Orchestrator
  alias Loomkin.Teams.Agent

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
    "test-integ-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(overrides \\ []) do
    team_id = Keyword.get(overrides, :team_id, unique_team_id())
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)

    opts =
      [team_id: team_id, name: name, role: role]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name}
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
          failure_count: 2
      }
    end)
  end

  defp healing_context(overrides \\ %{}) do
    Map.merge(
      %{
        classification: %{
          category: :compile_error,
          severity: :medium,
          healable: true,
          error_context: %{file_path: "lib/foo.ex", line: 10},
          suggested_approach: "Check imports"
        }
      },
      overrides
    )
  end

  # -- Happy path: request → diagnose → fix → wake -------------------------

  describe "happy path lifecycle" do
    test "full cycle: request → diagnose → fix → wake" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      # Step 1: Request healing
      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      session = Orchestrator.get_session(session_id)
      assert session.status == :diagnosing
      assert session.team_id == team_id
      assert session.agent_name == name
      assert session.attempts == 0

      # Step 2: Diagnosis report arrives
      diagnosis = %{
        root_cause: "Missing alias for Foo.Bar module",
        affected_files: ["lib/foo.ex"],
        suggested_fix: "Add alias Foo.Bar at top of module",
        severity: :medium,
        confidence: 0.9
      }

      :ok = Orchestrator.report_diagnosis(session_id, diagnosis)

      session = Orchestrator.get_session(session_id)
      assert session.status == :fixing
      assert session.diagnosis == diagnosis
      assert session.attempts == 1

      # Step 3: Fix confirmation
      fix_result = %{
        description: "Added alias Foo.Bar to module header",
        files_changed: ["lib/foo.ex"],
        verification_output: "mix compile: 0 warnings, 0 errors"
      }

      :ok = Orchestrator.confirm_fix(session_id, fix_result)

      # Session should be cleaned up
      assert Orchestrator.get_session(session_id) == nil
      assert Orchestrator.active_sessions(team_id) == []

      # Agent should be woken and idle
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.frozen_state == nil
      assert state.failure_count == 0

      # Healing summary should be in messages
      last_msg = List.last(state.messages)
      assert last_msg.role == :system
      assert last_msg.content =~ "Healing complete"
      assert last_msg.content =~ "Missing alias for Foo.Bar module"
    end
  end

  # -- Retry path: diagnose → fix fails → re-diagnose → fix → wake ---------

  describe "retry path" do
    test "retries diagnosis after first fix failure" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      # First diagnosis
      :ok =
        Orchestrator.report_diagnosis(session_id, %{
          root_cause: "Wrong import",
          suggested_fix: "Change import"
        })

      session = Orchestrator.get_session(session_id)
      assert session.status == :fixing
      assert session.attempts == 1

      # First fix fails
      :ok = Orchestrator.fix_failed(session_id, "Import change caused new error")

      session = Orchestrator.get_session(session_id)
      assert session.status == :diagnosing
      assert session.attempts == 1

      # Second diagnosis with revised understanding
      :ok =
        Orchestrator.report_diagnosis(session_id, %{
          root_cause: "Missing alias, not import",
          suggested_fix: "Add alias statement"
        })

      session = Orchestrator.get_session(session_id)
      assert session.status == :fixing
      assert session.attempts == 2

      # Second fix succeeds
      :ok =
        Orchestrator.confirm_fix(session_id, %{
          description: "Added correct alias",
          files_changed: ["lib/foo.ex"]
        })

      assert Orchestrator.get_session(session_id) == nil

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
    end

    test "escalates after max attempts exhausted" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      # Attempt 1: diagnose then fail
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug A"})
      :ok = Orchestrator.fix_failed(session_id, "Fix A didn't work")

      # Attempt 2: diagnose then fail
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug B"})
      :ok = Orchestrator.fix_failed(session_id, "Fix B didn't work either")

      # Session should be removed (max_attempts=2 reached)
      assert Orchestrator.get_session(session_id) == nil

      # Agent should be woken with failure summary
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "Healing failed"
    end
  end

  # -- Timeout path ---------------------------------------------------------

  describe "timeout path" do
    test "timeout wakes agent with failure message" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      # Simulate timeout by sending the message directly
      send(Process.whereis(Orchestrator), {:healing_timeout, session_id})
      _ = :sys.get_state(Process.whereis(Orchestrator))

      # Session removed
      assert Orchestrator.get_session(session_id) == nil

      # Agent woken with timeout message
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "timed out"
    end

    test "timeout during fixing phase still wakes agent" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug"})

      session = Orchestrator.get_session(session_id)
      assert session.status == :fixing

      # Timeout fires during fixing
      send(Process.whereis(Orchestrator), {:healing_timeout, session_id})
      _ = :sys.get_state(Process.whereis(Orchestrator))

      assert Orchestrator.get_session(session_id) == nil

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
    end
  end

  # -- Concurrent sessions --------------------------------------------------

  describe "concurrent sessions" do
    test "two agents in same team heal independently" do
      team_id = unique_team_id()

      %{pid: pid1, name: name1} =
        start_agent(team_id: team_id, name: "coder-1")

      %{pid: pid2, name: name2} =
        start_agent(team_id: team_id, name: "researcher-1")

      suspend_agent(pid1)
      suspend_agent(pid2)

      {:ok, sid1} = Orchestrator.request_healing(team_id, name1, healing_context())
      {:ok, sid2} = Orchestrator.request_healing(team_id, name2, healing_context())

      assert sid1 != sid2
      assert length(Orchestrator.active_sessions(team_id)) == 2

      # Fix agent 1 only
      :ok = Orchestrator.report_diagnosis(sid1, %{root_cause: "Bug in coder"})
      :ok = Orchestrator.confirm_fix(sid1, %{description: "Fixed coder", files_changed: []})

      # Agent 1 woken, agent 2 still healing
      _ = :sys.get_state(pid1)
      assert :sys.get_state(pid1).status == :idle

      _ = :sys.get_state(pid2)
      assert :sys.get_state(pid2).status == :suspended_healing

      assert length(Orchestrator.active_sessions(team_id)) == 1
      assert Orchestrator.get_session(sid2).status == :diagnosing

      # Now fix agent 2
      :ok = Orchestrator.report_diagnosis(sid2, %{root_cause: "Bug in researcher"})

      :ok =
        Orchestrator.confirm_fix(sid2, %{description: "Fixed researcher", files_changed: []})

      _ = :sys.get_state(pid2)
      assert :sys.get_state(pid2).status == :idle
      assert Orchestrator.active_sessions(team_id) == []
    end

    test "sessions across different teams are isolated" do
      %{pid: pid1, team_id: team_a, name: name1} = start_agent()
      %{pid: pid2, team_id: team_b, name: name2} = start_agent()
      suspend_agent(pid1)
      suspend_agent(pid2)

      {:ok, sid1} = Orchestrator.request_healing(team_a, name1, healing_context())
      {:ok, sid2} = Orchestrator.request_healing(team_b, name2, healing_context())

      assert Orchestrator.active_sessions(team_a) |> length() == 1
      assert Orchestrator.active_sessions(team_b) |> length() == 1

      # Cancel team_a session — team_b unaffected
      :ok = Orchestrator.cancel_healing(sid1)
      assert Orchestrator.active_sessions(team_a) == []
      assert Orchestrator.active_sessions(team_b) |> length() == 1

      # Clean up team_b
      :ok = Orchestrator.cancel_healing(sid2)
    end
  end

  # -- Cancellation ---------------------------------------------------------

  describe "cancellation" do
    test "cancel mid-diagnosis wakes agent" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())
      assert Orchestrator.get_session(session_id).status == :diagnosing

      :ok = Orchestrator.cancel_healing(session_id)

      assert Orchestrator.get_session(session_id) == nil

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "cancelled"
    end

    test "cancel mid-fixing wakes agent" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug"})
      assert Orchestrator.get_session(session_id).status == :fixing

      :ok = Orchestrator.cancel_healing(session_id)

      assert Orchestrator.get_session(session_id) == nil

      _ = :sys.get_state(pid)
      assert :sys.get_state(pid).status == :idle
    end

    test "cancel non-existent session returns error" do
      assert {:error, :not_found} = Orchestrator.cancel_healing("nonexistent-id")
    end
  end

  # -- Double-wake idempotency ----------------------------------------------

  describe "double-wake idempotency" do
    test "waking an already-idle agent is a no-op" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      # First wake
      Agent.wake_from_healing(pid, %{description: "First fix"})
      _ = :sys.get_state(pid)
      assert :sys.get_state(pid).status == :idle

      # Second wake — should be no-op
      Agent.wake_from_healing(pid, %{description: "Second fix"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :idle
      # Messages should only have one healing summary, not two
      healing_msgs =
        Enum.filter(state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content || "", "Healing complete")
        end)

      assert length(healing_msgs) == 1
    end
  end

  # -- Error classification → healing trigger integration -------------------

  describe "error classification to healing trigger" do
    test "compile error above threshold triggers healing" do
      error = "** (CompileError) lib/foo.ex:10: undefined function bar/1"
      classification = ErrorClassifier.classify(error)

      assert classification.category == :compile_error
      assert classification.healable == true

      assert ErrorClassifier.should_heal?(classification, %{failure_count: 1})
    end

    test "compile error below threshold does not trigger" do
      error = "** (CompileError) lib/foo.ex:10: undefined function bar/1"
      classification = ErrorClassifier.classify(error)

      refute ErrorClassifier.should_heal?(classification, %{failure_count: 0})
    end

    test "resource error never triggers healing" do
      error = "Rate limit exceeded, retry after 30s"
      classification = ErrorClassifier.classify(error)

      assert classification.category == :resource_error
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 10})
    end

    test "full classify → should_heal? → request_healing flow" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      error = "** (CompileError) lib/foo.ex:42: undefined function helper/0"
      classification = ErrorClassifier.classify(error)
      assert ErrorClassifier.should_heal?(classification, %{failure_count: 2})

      ctx = %{classification: classification, error_text: error}
      {:ok, session_id} = Orchestrator.request_healing(team_id, name, ctx)

      session = Orchestrator.get_session(session_id)
      assert session.classification == classification
      assert session.status == :diagnosing

      # Clean up
      :ok = Orchestrator.cancel_healing(session_id)
    end
  end

  # -- Queued tasks drain on wake -------------------------------------------

  describe "queued tasks drain on wake" do
    test "tasks queued during healing are drained after wake" do
      %{pid: pid} = start_agent()
      suspend_agent(pid)

      # Queue tasks while suspended
      Agent.assign_task(pid, %{id: "t1", title: "queued task 1"})
      Agent.assign_task(pid, %{id: "t2", title: "queued task 2"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.healing_queue) == 2

      # Wake agent
      Agent.wake_from_healing(pid, %{description: "Fixed"})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.healing_queue == []
      assert state.status == :idle
    end
  end

  # -- Stale timeout is safe ------------------------------------------------

  describe "stale timeout handling" do
    test "timeout for already-completed session is a no-op" do
      team_id = unique_team_id()
      {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())

      # Complete the session via cancel
      :ok = Orchestrator.cancel_healing(session_id)

      # Stale timeout arrives — should not crash
      send(Process.whereis(Orchestrator), {:healing_timeout, session_id})
      _ = :sys.get_state(Process.whereis(Orchestrator))

      # Orchestrator still operational
      assert Orchestrator.active_sessions(team_id) == []
    end

    test "timeout for never-created session is a no-op" do
      send(Process.whereis(Orchestrator), {:healing_timeout, "nonexistent-session"})
      _ = :sys.get_state(Process.whereis(Orchestrator))

      # Orchestrator still functional
      assert Orchestrator.active_sessions("any-team") == []
    end
  end

  # -- Operations on non-existent sessions ----------------------------------

  describe "operations on non-existent sessions" do
    test "report_diagnosis for unknown session returns error" do
      assert {:error, :not_found} = Orchestrator.report_diagnosis("bad-id", %{root_cause: "x"})
    end

    test "confirm_fix for unknown session returns error" do
      assert {:error, :not_found} = Orchestrator.confirm_fix("bad-id", %{description: "x"})
    end

    test "fix_failed for unknown session returns error" do
      assert {:error, :not_found} = Orchestrator.fix_failed("bad-id", "reason")
    end

    test "get_session for unknown session returns nil" do
      assert Orchestrator.get_session("bad-id") == nil
    end
  end
end
