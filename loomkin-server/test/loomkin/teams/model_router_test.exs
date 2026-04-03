defmodule Loomkin.Teams.ModelRouterTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.ModelRouter

  setup do
    ModelRouter.init()

    # Use a unique team_id per test to avoid ETS cross-contamination
    team_id = "mr-test-#{:erlang.unique_integer([:positive])}"
    %{team_id: team_id}
  end

  # ── select/2 — uniform model default ───────────────────────────────────

  describe "select/2" do
    test "all roles return the same default model" do
      default = ModelRouter.default_model()

      assert default == ModelRouter.select(:lead)
      assert default == ModelRouter.select(:coder)
      assert default == ModelRouter.select(:researcher)
      assert default == ModelRouter.select(:reviewer)
      assert default == ModelRouter.select(:tester)
    end

    test "unknown role also returns default model" do
      assert ModelRouter.default_model() == ModelRouter.select(:nonexistent)
    end

    test "task model_hint overrides default (atom hint)" do
      assert "zai:glm-5" = ModelRouter.select(:coder, %{model_hint: :architect})
    end

    test "task model_hint overrides default (string tier hint)" do
      assert "zai:glm-4.5" = ModelRouter.select(:lead, %{model_hint: "grunt"})
    end

    test "task model_hint as full model string passes through" do
      assert "custom:model-v1" = ModelRouter.select(:coder, %{model_hint: "custom:model-v1"})
    end

    test "task without model_hint falls back to default" do
      assert ModelRouter.default_model() ==
               ModelRouter.select(:coder, %{description: "some task"})
    end

    test "nil task falls back to default" do
      assert ModelRouter.default_model() == ModelRouter.select(:coder, nil)
    end
  end

  # ── escalate/1 — opt-in only ───────────────────────────────────────────

  describe "escalate/1" do
    test "returns :disabled when no escalation chain is configured" do
      # Without Config running or escalation configured, escalation is disabled
      assert :disabled = ModelRouter.escalate("zai:glm-5")
      assert :disabled = ModelRouter.escalate("anthropic:claude-sonnet-4-6")
    end
  end

  describe "escalation_enabled?/0" do
    test "returns false when no escalation is configured" do
      refute ModelRouter.escalation_enabled?()
    end
  end

  # ── tier_for_model/1 (legacy compat) ───────────────────────────────────

  describe "tier_for_model/1" do
    test "returns correct tier for known models" do
      assert :grunt = ModelRouter.tier_for_model("zai:glm-4.5")
      # glm-5 is mapped to multiple tiers; tier_for_model returns the last-written key
      tier = ModelRouter.tier_for_model("zai:glm-5")
      assert tier in [:standard, :expert, :architect]
    end

    test "returns :standard for unknown model" do
      assert :standard = ModelRouter.tier_for_model("unknown:model")
    end
  end

  # ── tiers/0 (legacy compat) ────────────────────────────────────────────

  describe "tiers/0" do
    test "returns all four legacy tiers in order" do
      assert [:grunt, :standard, :expert, :architect] = ModelRouter.tiers()
    end
  end

  # ── default_model/0 ────────────────────────────────────────────────────

  describe "default_model/0" do
    test "returns fallback when Config is not running" do
      model = ModelRouter.default_model()
      assert is_binary(model)
      assert String.contains?(model, ":")
    end
  end

  # ── record_failure/3 & should_escalate? (ETS) ────────────────────────

  describe "record_failure/3" do
    test "increments failure count for agent/task", %{team_id: team_id} do
      assert 0 = ModelRouter.get_failure_count(team_id, "coder", "task-1")

      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      assert 1 = ModelRouter.get_failure_count(team_id, "coder", "task-1")

      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      assert 2 = ModelRouter.get_failure_count(team_id, "coder", "task-1")
    end

    test "failures are scoped per agent and task", %{team_id: team_id} do
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(team_id, "researcher", "task-1")

      assert 2 = ModelRouter.get_failure_count(team_id, "coder", "task-1")
      assert 1 = ModelRouter.get_failure_count(team_id, "researcher", "task-1")
      assert 0 = ModelRouter.get_failure_count(team_id, "coder", "task-2")
    end
  end

  describe "should_escalate?/1 and should_escalate?/2 (simple integer)" do
    test "returns false when below default threshold of 2" do
      refute ModelRouter.should_escalate?(0)
      refute ModelRouter.should_escalate?(1)
    end

    test "returns true when at or above default threshold of 2" do
      assert ModelRouter.should_escalate?(2)
      assert ModelRouter.should_escalate?(5)
    end

    test "respects custom threshold" do
      refute ModelRouter.should_escalate?(2, 3)
      assert ModelRouter.should_escalate?(3, 3)
      assert ModelRouter.should_escalate?(4, 3)
    end
  end

  describe "should_escalate?/3 and should_escalate?/4 (ETS-backed)" do
    test "returns false when no failures recorded", %{team_id: team_id} do
      refute ModelRouter.should_escalate?(team_id, "coder", "task-1")
    end

    test "returns false below threshold, true at threshold", %{team_id: team_id} do
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      refute ModelRouter.should_escalate?(team_id, "coder", "task-1")

      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      assert ModelRouter.should_escalate?(team_id, "coder", "task-1")
    end

    test "respects custom threshold via 4-arity", %{team_id: team_id} do
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")

      refute ModelRouter.should_escalate?(team_id, "coder", "task-1", 4)
      assert ModelRouter.should_escalate?(team_id, "coder", "task-1", 3)
    end
  end

  # ── record_success/4 & get_success_rate/1 ─────────────────────────────

  describe "record_success/4" do
    test "tracks successes for an agent/task", %{team_id: team_id} do
      :ok = ModelRouter.record_success(team_id, "coder", "task-1", "zai:glm-5")
      :ok = ModelRouter.record_success(team_id, "coder", "task-1", "anthropic:claude-sonnet-4-6")

      # Success rate for glm-5: 1 success / 1 attempt = 1.0
      assert ModelRouter.get_success_rate("zai:glm-5") == 1.0
    end
  end

  describe "get_success_rate/1" do
    test "returns 1.0 (optimistic) for model with no attempts" do
      assert 1.0 == ModelRouter.get_success_rate("never-used-model")
    end

    test "returns correct rate after recording attempts and successes" do
      fresh_model = "fresh-rate-model-#{:erlang.unique_integer([:positive])}"

      # 2 attempts (failures)
      :ok = ModelRouter.record_attempt(fresh_model)
      :ok = ModelRouter.record_attempt(fresh_model)

      # 1 success (also counts as an attempt)
      :ok = ModelRouter.record_success("any-team", "agent", "task", fresh_model)

      # Total: 1 success / 3 attempts = 0.333...
      rate = ModelRouter.get_success_rate(fresh_model)
      assert_in_delta rate, 1 / 3, 0.001
    end
  end

  # ── reset_tracking/1 ──────────────────────────────────────────────────

  describe "reset_tracking/1" do
    test "clears all failure and success data for a team", %{team_id: team_id} do
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_success(team_id, "coder", "task-1", "zai:glm-5")

      assert ModelRouter.get_failure_count(team_id, "coder", "task-1") == 2

      :ok = ModelRouter.reset_tracking(team_id)

      assert ModelRouter.get_failure_count(team_id, "coder", "task-1") == 0
    end

    test "does not affect other teams", %{team_id: team_id} do
      other_team = "other-#{:erlang.unique_integer([:positive])}"

      :ok = ModelRouter.record_failure(team_id, "coder", "task-1")
      :ok = ModelRouter.record_failure(other_team, "coder", "task-1")

      :ok = ModelRouter.reset_tracking(team_id)

      assert ModelRouter.get_failure_count(team_id, "coder", "task-1") == 0
      assert ModelRouter.get_failure_count(other_team, "coder", "task-1") == 1

      # Clean up
      ModelRouter.reset_tracking(other_team)
    end

    test "is idempotent on empty team" do
      assert :ok = ModelRouter.reset_tracking("nonexistent-team-xyz")
    end
  end

  # ── configured_tiers/0 (legacy compat) ─────────────────────────────────

  describe "configured_tiers/0" do
    test "returns legacy tier models when Config is not running" do
      tiers = ModelRouter.configured_tiers()
      assert tiers[:grunt] == "zai:glm-4.5"
      assert tiers[:standard] == "zai:glm-5"
      assert tiers[:expert] == "zai:glm-5"
      assert tiers[:architect] == "zai:glm-5"
    end
  end

  # ── configured_escalation_chain/0 ─────────────────────────────────────

  describe "configured_escalation_chain/0" do
    test "returns :disabled when no escalation is configured" do
      assert :disabled = ModelRouter.configured_escalation_chain()
    end
  end
end
