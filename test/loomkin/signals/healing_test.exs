defmodule Loomkin.Signals.HealingTest do
  use ExUnit.Case, async: true

  alias Loomkin.Signals.Healing

  describe "SessionStarted" do
    test "creates a valid signal with required fields" do
      signal =
        Healing.SessionStarted.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          classification: %{category: :compile_error, severity: :medium}
        })

      assert signal.type == "healing.session.started"
      assert signal.data.session_id == "sess-123"
      assert signal.data.team_id == "team-abc"
      assert signal.data.agent_name == "coder-1"
      assert signal.data.classification == %{category: :compile_error, severity: :medium}
    end
  end

  describe "DiagnosisComplete" do
    test "creates a valid signal with required fields" do
      signal =
        Healing.DiagnosisComplete.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          root_cause: "missing import for Enum module",
          confidence: 0.92
        })

      assert signal.type == "healing.diagnosis.complete"
      assert signal.data.root_cause == "missing import for Enum module"
      assert signal.data.confidence == 0.92
    end
  end

  describe "FixApplied" do
    test "creates a valid signal with required fields" do
      signal =
        Healing.FixApplied.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          files_changed: ["lib/my_module.ex", "lib/my_other.ex"]
        })

      assert signal.type == "healing.fix.applied"
      assert signal.data.files_changed == ["lib/my_module.ex", "lib/my_other.ex"]
    end
  end

  describe "SessionComplete" do
    test "creates a valid signal with :healed outcome" do
      signal =
        Healing.SessionComplete.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :healed,
          duration_ms: 15_000
        })

      assert signal.type == "healing.session.complete"
      assert signal.data.outcome == :healed
      assert signal.data.duration_ms == 15_000
    end

    test "creates a valid signal with :escalated outcome" do
      signal =
        Healing.SessionComplete.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :escalated,
          duration_ms: 300_000
        })

      assert signal.data.outcome == :escalated
    end

    test "creates a valid signal with :timed_out outcome" do
      signal =
        Healing.SessionComplete.new!(%{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :timed_out,
          duration_ms: 300_000
        })

      assert signal.data.outcome == :timed_out
    end
  end
end
