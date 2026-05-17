defmodule Loomkin.OrchestrationTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration

  test "phases returns the 9 canonical phases in order" do
    phases = Orchestration.phases()
    assert length(phases) == 9
    assert hd(phases) == :research
    assert List.last(phases) == :closure
  end

  test "work_unit_phases returns the 4 canonical states in order" do
    assert Orchestration.work_unit_phases() ==
             [:implement, :validate, :adversarial_review, :commit]
  end

  test "max_gate_iterations defaults to 5 (matching the retry ladder)" do
    assert Orchestration.max_gate_iterations() == 5
  end

  test "attempt_strategy/2 delegates to RetryLadder" do
    assert Orchestration.attempt_strategy(:gate, 1).strategy == :default
    assert Orchestration.attempt_strategy(:gate, 6) == :escalate
  end
end
