defmodule Loomkin.Orchestration.PersonasTest do
  @moduledoc """
  Verifies the Personas registry resolves the right persona for each
  phase / gate / event shape emitted by IssueOrchestrator.
  """
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Personas

  describe "for_phase/1" do
    test "resolves the Plan Council for :plan_review" do
      persona = Personas.for_phase(:plan_review)
      assert persona.name == "Plan Council"
      assert persona.icon == "⚖️"
      assert is_binary(persona.role_blurb)
    end

    test "resolves the Researcher for :research" do
      assert %{name: "Researcher", icon: "🔬"} = Personas.for_phase(:research)
    end

    test "resolves the Design Council for :design_review" do
      assert %{name: "Design Council"} = Personas.for_phase(:design_review)
    end

    test "resolves the Executor for :execute" do
      assert %{name: "Executor"} = Personas.for_phase(:execute)
    end

    test "unknown phase falls back to the System persona" do
      assert %{name: "System"} = Personas.for_phase(:not_a_real_phase)
    end
  end

  describe "for_gate/1" do
    test "resolves the Plan Council for :plan_review" do
      assert %{name: "Plan Council"} = Personas.for_gate(:plan_review)
    end

    test "resolves the Adversarial Reviewer for :adversarial_review" do
      assert %{name: "Adversarial Reviewer"} = Personas.for_gate(:adversarial_review)
    end

    test "unknown gate falls back to System" do
      assert %{name: "System"} = Personas.for_gate(:bogus_gate)
    end
  end

  describe "for_work_unit_state/1" do
    test "resolves the Coder for :implement" do
      assert %{name: "Coder"} = Personas.for_work_unit_state(:implement)
    end

    test "resolves the Validator for :validate" do
      assert %{name: "Validator"} = Personas.for_work_unit_state(:validate)
    end

    test "resolves the DoD Verifier for :adversarial_review" do
      assert %{name: "DoD Verifier"} = Personas.for_work_unit_state(:adversarial_review)
    end

    test "resolves the Committer for :commit and :done" do
      assert %{name: "Committer"} = Personas.for_work_unit_state(:commit)
      assert %{name: "Committer"} = Personas.for_work_unit_state(:done)
    end
  end

  describe "for_event/2 — epic subtype" do
    test "{:phase_entered, :research} → Researcher" do
      assert %{name: "Researcher"} =
               Personas.for_event(:epic, %{event: {:phase_entered, :research}})
    end

    test "{:phase_entered, :plan_review} → Plan Council" do
      assert %{name: "Plan Council"} =
               Personas.for_event(:epic, %{event: {:phase_entered, :plan_review}})
    end

    test "{:escalated, _} → Escalator" do
      assert %{name: "Escalator"} =
               Personas.for_event(:epic, %{event: {:escalated, "human attention"}})
    end

    test ":closed atom → closed persona" do
      assert %{name: "Curator", icon: "✅"} = Personas.for_event(:epic, %{event: :closed})
    end

    test ":failed atom → failed persona" do
      assert %{name: "System", icon: "❌"} = Personas.for_event(:epic, %{event: :failed})
    end
  end

  describe "for_event/2 — gate subtype" do
    test "{:gate_verdict, :plan_review, :pass, 3} → Plan Council" do
      assert %{name: "Plan Council"} =
               Personas.for_event(:gate, %{
                 event: {:gate_verdict, :plan_review, :pass, 3}
               })
    end

    test "{:gate_verdict, :design_review, :fail, 1} → Design Council" do
      assert %{name: "Design Council"} =
               Personas.for_event(:gate, %{
                 event: {:gate_verdict, :design_review, :fail, 1}
               })
    end
  end

  describe "for_event/2 — work_unit subtype" do
    test ":completed → Committer (done)" do
      assert %{name: "Committer", icon: "✅"} =
               Personas.for_event(:work_unit, %{event: :completed})
    end

    test ":failed → System (failed)" do
      assert %{name: "System", icon: "❌"} =
               Personas.for_event(:work_unit, %{event: :failed})
    end

    test "{:retry, :implement, _} → Coder" do
      assert %{name: "Coder"} =
               Personas.for_event(:work_unit, %{event: {:retry, :implement, "reason"}})
    end

    test "{:review_pass, _} and {:review_fail, _} → DoD Verifier" do
      assert %{name: "DoD Verifier"} =
               Personas.for_event(:work_unit, %{event: {:review_pass, %{}}})

      assert %{name: "DoD Verifier"} =
               Personas.for_event(:work_unit, %{event: {:review_fail, %{}}})
    end

    test ":validate_pass and {:validate_fail, _} → Validator" do
      assert %{name: "Validator"} =
               Personas.for_event(:work_unit, %{event: :validate_pass})

      assert %{name: "Validator"} =
               Personas.for_event(:work_unit, %{event: {:validate_fail, "boom"}})
    end

    test "{:commit_done, sha} → Committer" do
      assert %{name: "Committer"} =
               Personas.for_event(:work_unit, %{event: {:commit_done, "abc1234"}})
    end

    test ":started and :implement_complete → Coder" do
      assert %{name: "Coder"} = Personas.for_event(:work_unit, %{event: :started})
      assert %{name: "Coder"} = Personas.for_event(:work_unit, %{event: :implement_complete})
    end
  end

  describe "for_event/2 — knowledge subtype" do
    test "always returns the Curator persona" do
      assert %{name: "Curator", icon: "📚"} = Personas.for_event(:knowledge, %{event: nil})

      assert %{name: "Curator"} =
               Personas.for_event(:knowledge, %{event: {:fact_added, "x"}})
    end
  end

  describe "for_event/2 — fallback" do
    test "missing or unknown event yields the System persona" do
      assert %{name: "System"} = Personas.for_event(:epic, %{})
      assert %{name: "System"} = Personas.for_event(:epic, %{event: :not_a_real_event})
    end

    test "non-map payload yields the System persona" do
      assert %{name: "System"} = Personas.for_event(:epic, :not_a_map)
    end
  end

  describe "all/0" do
    test "exposes a non-empty map of personas for the onboarding tour" do
      personas = Personas.all()
      assert map_size(personas) > 0
      assert is_map(personas[:research])
    end
  end
end
