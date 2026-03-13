defmodule Loomkin.Healing.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Loomkin.Healing.Orchestrator
  alias Loomkin.Healing.Session
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
    "test-orch-#{:erlang.unique_integer([:positive])}"
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

  defp healing_context do
    %{
      classification: %{
        category: :compile_error,
        severity: :medium,
        healable: true,
        error_context: %{file_path: "lib/foo.ex", line: 10},
        suggested_approach: "Check imports"
      }
    }
  end

  # -- request_healing/3 -------------------------------------------------------

  describe "request_healing/3" do
    test "creates a session and returns session id" do
      team_id = unique_team_id()
      assert {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())
      assert is_binary(session_id)
    end

    test "session starts in :diagnosing status" do
      team_id = unique_team_id()
      {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())

      session = Orchestrator.get_session(session_id)
      assert %Session{} = session
      assert session.status == :diagnosing
      assert session.team_id == team_id
      assert session.agent_name == :coder
      assert session.attempts == 0
    end

    test "session appears in active_sessions" do
      team_id = unique_team_id()
      {:ok, _session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())

      sessions = Orchestrator.active_sessions(team_id)
      assert length(sessions) == 1
      assert hd(sessions).team_id == team_id
    end

    test "concurrent sessions for different agents don't interfere" do
      team_id = unique_team_id()
      {:ok, id1} = Orchestrator.request_healing(team_id, :coder, healing_context())
      {:ok, id2} = Orchestrator.request_healing(team_id, :researcher, healing_context())

      assert id1 != id2

      sessions = Orchestrator.active_sessions(team_id)
      assert length(sessions) == 2

      names = Enum.map(sessions, & &1.agent_name) |> Enum.sort()
      assert names == [:coder, :researcher]
    end
  end

  # -- report_diagnosis/2 ------------------------------------------------------

  describe "report_diagnosis/2" do
    test "transitions session to :fixing" do
      team_id = unique_team_id()
      {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())

      diagnosis = %{root_cause: "Missing alias", suggested_fix: "Add alias Foo.Bar"}
      assert :ok = Orchestrator.report_diagnosis(session_id, diagnosis)

      session = Orchestrator.get_session(session_id)
      assert session.status == :fixing
      assert session.diagnosis == diagnosis
      assert session.attempts == 1
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Orchestrator.report_diagnosis("nonexistent", %{})
    end
  end

  # -- confirm_fix/2 -----------------------------------------------------------

  describe "confirm_fix/2" do
    test "wakes agent and removes session" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Missing import"})

      fix_result = %{description: "Added import statement", files_changed: ["lib/foo.ex"]}
      assert :ok = Orchestrator.confirm_fix(session_id, fix_result)

      # Session should be removed
      assert Orchestrator.get_session(session_id) == nil

      # Agent should be woken
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.failure_count == 0
    end

    test "injects healing summary into agent messages" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Typo in function name"})

      :ok = Orchestrator.confirm_fix(session_id, %{description: "Fixed typo"})

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      last_msg = List.last(state.messages)
      assert last_msg.role == :system
      assert last_msg.content =~ "Healing complete"
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Orchestrator.confirm_fix("nonexistent", %{})
    end
  end

  # -- fix_failed/2 ------------------------------------------------------------

  describe "fix_failed/2" do
    test "retries when under max_attempts" do
      team_id = unique_team_id()
      {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug"})

      # First fix fails — should retry (attempt 1 < max 2)
      assert :ok = Orchestrator.fix_failed(session_id, "Fix didn't work")

      session = Orchestrator.get_session(session_id)
      assert session.status == :diagnosing
    end

    test "escalates when max_attempts reached" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      # First attempt
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug"})
      :ok = Orchestrator.fix_failed(session_id, "Attempt 1 failed")

      # Second attempt
      :ok = Orchestrator.report_diagnosis(session_id, %{root_cause: "Bug v2"})
      :ok = Orchestrator.fix_failed(session_id, "Attempt 2 failed")

      # Session should be removed after max attempts
      assert Orchestrator.get_session(session_id) == nil

      # Agent should be woken with failure
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "Healing failed"
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Orchestrator.fix_failed("nonexistent", "reason")
    end
  end

  # -- cancel_healing/1 --------------------------------------------------------

  describe "cancel_healing/1" do
    test "cancels session and wakes agent" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      assert :ok = Orchestrator.cancel_healing(session_id)

      # Session removed
      assert Orchestrator.get_session(session_id) == nil

      # Agent woken with failure message
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "cancelled"
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Orchestrator.cancel_healing("nonexistent")
    end
  end

  # -- timeout handling --------------------------------------------------------

  describe "timeout handling" do
    test "times out and wakes agent after timeout" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()
      suspend_agent(pid)

      {:ok, session_id} = Orchestrator.request_healing(team_id, name, healing_context())

      # Simulate timeout by sending the timeout message directly
      send(Process.whereis(Orchestrator), {:healing_timeout, session_id})

      # Allow processing
      _ = :sys.get_state(Process.whereis(Orchestrator))

      # Session should be removed
      assert Orchestrator.get_session(session_id) == nil

      # Agent should be woken with timeout message
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
      last_msg = List.last(state.messages)
      assert last_msg.content =~ "timed out"
    end

    test "timeout for already-completed session is a no-op" do
      team_id = unique_team_id()
      {:ok, session_id} = Orchestrator.request_healing(team_id, :coder, healing_context())

      # Manually remove the session (simulating completion)
      :ok = Orchestrator.cancel_healing(session_id)

      # Simulate a late timeout — should not crash
      send(Process.whereis(Orchestrator), {:healing_timeout, session_id})
      _ = :sys.get_state(Process.whereis(Orchestrator))

      # Orchestrator still functional
      assert Orchestrator.active_sessions(team_id) == []
    end
  end

  # -- active_sessions/1 -------------------------------------------------------

  describe "active_sessions/1" do
    test "returns empty list for team with no sessions" do
      assert Orchestrator.active_sessions("nonexistent-team") == []
    end

    test "filters by team_id" do
      team_a = unique_team_id()
      team_b = unique_team_id()

      {:ok, _} = Orchestrator.request_healing(team_a, :coder, healing_context())
      {:ok, _} = Orchestrator.request_healing(team_b, :researcher, healing_context())

      assert length(Orchestrator.active_sessions(team_a)) == 1
      assert length(Orchestrator.active_sessions(team_b)) == 1
    end
  end

  # -- Session struct ----------------------------------------------------------

  describe "Session struct" do
    test "has correct defaults" do
      session = %Session{}
      assert session.budget_remaining_usd == 0.50
      assert session.max_iterations == 15
      assert session.attempts == 0
      assert session.max_attempts == 2
    end
  end
end
