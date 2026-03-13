defmodule Loomkin.Healing.SessionTest do
  use ExUnit.Case, async: true

  alias Loomkin.Healing.Session

  describe "struct defaults" do
    test "has correct default values" do
      session = %Session{}
      assert session.budget_remaining_usd == 0.50
      assert session.max_iterations == 15
      assert session.attempts == 0
      assert session.max_attempts == 2
    end

    test "nil defaults for unset fields" do
      session = %Session{}
      assert session.id == nil
      assert session.team_id == nil
      assert session.agent_name == nil
      assert session.classification == nil
      assert session.error_context == nil
      assert session.status == nil
      assert session.diagnosis == nil
      assert session.fix_result == nil
      assert session.diagnostician_pid == nil
      assert session.fixer_pid == nil
      assert session.started_at == nil
    end
  end

  describe "struct creation" do
    test "creates with all fields populated" do
      now = DateTime.utc_now()

      session = %Session{
        id: "heal-123",
        team_id: "team-abc",
        agent_name: :coder,
        classification: %{category: :compile_error, severity: :medium},
        error_context: %{file_path: "lib/foo.ex"},
        status: :diagnosing,
        diagnosis: nil,
        fix_result: nil,
        diagnostician_pid: nil,
        fixer_pid: nil,
        started_at: now,
        budget_remaining_usd: 0.25,
        max_iterations: 10,
        attempts: 1,
        max_attempts: 3
      }

      assert session.id == "heal-123"
      assert session.team_id == "team-abc"
      assert session.agent_name == :coder
      assert session.status == :diagnosing
      assert session.budget_remaining_usd == 0.25
      assert session.max_iterations == 10
      assert session.attempts == 1
      assert session.max_attempts == 3
      assert session.started_at == now
    end

    test "agent_name accepts atom or string" do
      session_atom = %Session{agent_name: :researcher}
      assert session_atom.agent_name == :researcher

      session_string = %Session{agent_name: "researcher-1"}
      assert session_string.agent_name == "researcher-1"
    end
  end

  describe "status transitions" do
    test "all valid status values can be set" do
      statuses = [:diagnosing, :fixing, :complete, :failed, :timed_out, :cancelled]

      for status <- statuses do
        session = %Session{status: status}
        assert session.status == status
      end
    end

    test "session can transition through typical lifecycle" do
      session = %Session{id: "heal-1", status: :diagnosing, attempts: 0}

      # Diagnosis received -> fixing
      session = %{session | status: :fixing, attempts: session.attempts + 1}
      assert session.status == :fixing
      assert session.attempts == 1

      # Fix confirmed -> complete
      session = %{session | status: :complete}
      assert session.status == :complete
    end

    test "session can transition through retry path" do
      session = %Session{id: "heal-1", status: :diagnosing, attempts: 0}

      # First diagnosis -> fixing
      session = %{session | status: :fixing, attempts: 1}

      # Fix fails -> back to diagnosing
      session = %{session | status: :diagnosing}
      assert session.status == :diagnosing
      assert session.attempts == 1

      # Second diagnosis -> fixing
      session = %{session | status: :fixing, attempts: 2}
      assert session.attempts == 2

      # Fix succeeds -> complete
      session = %{session | status: :complete}
      assert session.status == :complete
    end

    test "session can transition to failure states" do
      session = %Session{id: "heal-1", status: :diagnosing}

      timed_out = %{session | status: :timed_out}
      assert timed_out.status == :timed_out

      cancelled = %{session | status: :cancelled}
      assert cancelled.status == :cancelled

      failed = %{session | status: :failed}
      assert failed.status == :failed
    end
  end

  describe "diagnosis and fix_result" do
    test "stores diagnosis map" do
      diagnosis = %{
        root_cause: "Missing alias",
        affected_files: ["lib/foo.ex"],
        suggested_fix: "Add alias Foo.Bar",
        severity: :medium,
        confidence: 0.85
      }

      session = %Session{diagnosis: diagnosis}
      assert session.diagnosis.root_cause == "Missing alias"
      assert session.diagnosis.confidence == 0.85
    end

    test "stores fix_result map" do
      fix_result = %{
        description: "Added missing import",
        files_changed: ["lib/foo.ex", "lib/bar.ex"],
        verification_output: "All tests pass"
      }

      session = %Session{fix_result: fix_result}
      assert session.fix_result.description == "Added missing import"
      assert length(session.fix_result.files_changed) == 2
    end
  end
end
