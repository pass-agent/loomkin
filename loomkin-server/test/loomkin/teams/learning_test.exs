defmodule Loomkin.Teams.LearningTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Learning

  defp insert_metric(attrs) do
    defaults = %{
      team_id: "test-team",
      agent_name: "coder",
      role: "developer",
      model: "anthropic:claude-sonnet-4-6",
      task_type: "code_edit",
      success: true,
      cost_usd: 0.05,
      tokens_used: 1000,
      duration_ms: 5000,
      project_path: "/tmp/test"
    }

    {:ok, metric} = Learning.record_task_result(Map.merge(defaults, attrs))
    metric
  end

  # ── record_task_result/1 ─────────────────────────────────────────────

  describe "record_task_result/1" do
    test "inserts a metric with all fields" do
      assert {:ok, metric} =
               Learning.record_task_result(%{
                 team_id: "team-1",
                 agent_name: "alice",
                 role: "reviewer",
                 model: "anthropic:claude-sonnet-4-6",
                 task_type: "review",
                 success: true,
                 cost_usd: 0.03,
                 tokens_used: 500,
                 duration_ms: 2000,
                 project_path: "/tmp/project"
               })

      assert metric.team_id == "team-1"
      assert metric.agent_name == "alice"
      assert metric.role == "reviewer"
      assert metric.model == "anthropic:claude-sonnet-4-6"
      assert metric.task_type == "review"
      assert metric.success == true
      assert metric.cost_usd == 0.03
      assert metric.tokens_used == 500
      assert metric.duration_ms == 2000
    end

    test "inserts with only required fields" do
      assert {:ok, metric} =
               Learning.record_task_result(%{
                 team_id: "team-1",
                 agent_name: "bob",
                 model: "zai:glm-5",
                 task_type: "code_edit",
                 success: false
               })

      assert metric.success == false
      assert metric.cost_usd == nil
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Learning.record_task_result(%{})
      refute changeset.valid?
    end
  end

  # ── success_rate/2 ───────────────────────────────────────────────────

  describe "success_rate/2" do
    test "returns success rate as float" do
      insert_metric(%{model: "m1", task_type: "edit", success: true})
      insert_metric(%{model: "m1", task_type: "edit", success: true})
      insert_metric(%{model: "m1", task_type: "edit", success: false})

      rate = Learning.success_rate("m1", "edit")
      assert_in_delta rate, 0.6667, 0.01
    end

    test "returns nil when no data exists" do
      assert Learning.success_rate("unknown-model", "unknown-type") == nil
    end

    test "returns 1.0 when all tasks succeed" do
      insert_metric(%{model: "m2", task_type: "test", success: true})
      insert_metric(%{model: "m2", task_type: "test", success: true})

      assert Learning.success_rate("m2", "test") == 1.0
    end

    test "returns 0.0 when all tasks fail" do
      insert_metric(%{model: "m3", task_type: "deploy", success: false})
      insert_metric(%{model: "m3", task_type: "deploy", success: false})

      assert Learning.success_rate("m3", "deploy") == 0.0
    end
  end

  # ── avg_cost/1 ──────────────────────────────────────────────────────

  describe "avg_cost/1" do
    test "returns average cost for a task type" do
      insert_metric(%{task_type: "review", cost_usd: 0.10})
      insert_metric(%{task_type: "review", cost_usd: 0.20})
      insert_metric(%{task_type: "review", cost_usd: 0.30})

      avg = Learning.avg_cost("review")
      assert_in_delta avg, 0.20, 0.001
    end

    test "returns nil when no data exists" do
      assert Learning.avg_cost("nonexistent") == nil
    end
  end

  # ── recommend_model/1 ───────────────────────────────────────────────

  describe "recommend_model/1" do
    test "recommends model with best success/cost ratio" do
      # Cheap model, 100% success
      insert_metric(%{model: "cheap", task_type: "fix", success: true, cost_usd: 0.01})
      insert_metric(%{model: "cheap", task_type: "fix", success: true, cost_usd: 0.01})

      # Expensive model, 100% success
      insert_metric(%{model: "expensive", task_type: "fix", success: true, cost_usd: 1.00})
      insert_metric(%{model: "expensive", task_type: "fix", success: true, cost_usd: 1.00})

      {model, _score} = Learning.recommend_model("fix")
      assert model == "cheap"
    end

    test "returns nil when no data exists" do
      assert Learning.recommend_model("nonexistent") == nil
    end

    test "prefers higher success rate over lower cost" do
      # Cheap but unreliable
      insert_metric(%{model: "cheap-bad", task_type: "build", success: true, cost_usd: 0.01})
      insert_metric(%{model: "cheap-bad", task_type: "build", success: false, cost_usd: 0.01})
      insert_metric(%{model: "cheap-bad", task_type: "build", success: false, cost_usd: 0.01})

      # Moderate cost, reliable
      insert_metric(%{model: "mid-good", task_type: "build", success: true, cost_usd: 0.10})
      insert_metric(%{model: "mid-good", task_type: "build", success: true, cost_usd: 0.10})
      insert_metric(%{model: "mid-good", task_type: "build", success: true, cost_usd: 0.10})

      {model, _score} = Learning.recommend_model("build")
      assert model == "mid-good"
    end
  end

  # ── recommend_team/1 ────────────────────────────────────────────────

  describe "recommend_team/1" do
    test "returns role/model combos sorted by success rate" do
      insert_metric(%{role: "developer", model: "m1", task_type: "code", success: true})
      insert_metric(%{role: "developer", model: "m1", task_type: "code", success: true})
      insert_metric(%{role: "reviewer", model: "m2", task_type: "code", success: true})
      insert_metric(%{role: "reviewer", model: "m2", task_type: "code", success: false})

      results = Learning.recommend_team("code")
      assert length(results) == 2

      [first | _] = results
      assert first.role == "developer"
      assert first.success_rate == 1.0
    end

    test "returns empty list when no data" do
      assert Learning.recommend_team("nonexistent") == []
    end
  end

  # ── top_performers/1 ────────────────────────────────────────────────

  describe "top_performers/1" do
    test "ranks models by success rate" do
      insert_metric(%{model: "good", task_type: "t", success: true})
      insert_metric(%{model: "good", task_type: "t", success: true})
      insert_metric(%{model: "bad", task_type: "t", success: false})
      insert_metric(%{model: "bad", task_type: "t", success: true})

      results = Learning.top_performers(group_by: :model)
      assert length(results) == 2
      assert hd(results).name == "good"
      assert hd(results).success_rate == 1.0
    end

    test "filters by task type" do
      insert_metric(%{model: "a", task_type: "x", success: true})
      insert_metric(%{model: "b", task_type: "y", success: true})

      results = Learning.top_performers(task_type: "x")
      assert length(results) == 1
      assert hd(results).name == "a"
    end

    test "groups by agent when specified" do
      insert_metric(%{agent_name: "alice", model: "m1", task_type: "t", success: true})
      insert_metric(%{agent_name: "bob", model: "m1", task_type: "t", success: false})

      results = Learning.top_performers(group_by: :agent)
      assert length(results) == 2
      assert hd(results).name == "alice"
    end

    test "respects limit" do
      for i <- 1..5 do
        insert_metric(%{model: "model-#{i}", task_type: "t", success: true})
      end

      results = Learning.top_performers(limit: 3)
      assert length(results) == 3
    end

    test "respects min_tasks" do
      insert_metric(%{model: "few", task_type: "t", success: true})
      insert_metric(%{model: "many", task_type: "t", success: true})
      insert_metric(%{model: "many", task_type: "t", success: true})
      insert_metric(%{model: "many", task_type: "t", success: true})

      results = Learning.top_performers(min_tasks: 3)
      assert length(results) == 1
      assert hd(results).name == "many"
    end
  end

  # ── avg_cost_by_scope/1 ─────────────────────────────────────────────

  describe "avg_cost_by_scope/1" do
    test "returns average cost for tasks of a given scope tier" do
      for cost <- [0.10, 0.20, 0.30, 0.40, 0.50] do
        insert_metric(%{scope_tier: "session", cost_usd: cost})
      end

      avg = Learning.avg_cost_by_scope(:session)
      assert_in_delta avg, 0.30, 0.001
    end

    test "accepts string tier" do
      insert_metric(%{scope_tier: "quick", cost_usd: 0.05})
      insert_metric(%{scope_tier: "quick", cost_usd: 0.15})

      avg = Learning.avg_cost_by_scope("quick")
      assert_in_delta avg, 0.10, 0.001
    end

    test "returns nil when no data exists for tier" do
      assert Learning.avg_cost_by_scope(:campaign) == nil
    end

    test "ignores records without scope_tier" do
      insert_metric(%{cost_usd: 0.50})
      insert_metric(%{scope_tier: "campaign", cost_usd: 0.20})

      assert Learning.avg_cost_by_scope(:campaign) == 0.20
    end
  end

  # ── recommend_tier/1 ───────────────────────────────────────────────

  describe "recommend_tier/1" do
    test "returns :learned with avg cost when 5+ records exist" do
      for _ <- 1..6 do
        insert_metric(%{scope_tier: "quick", cost_usd: 0.04})
      end

      assert {:learned, "quick", avg_cost} =
               Learning.recommend_tier(%{task_description: "fix typo", file_matches: 1})

      assert_in_delta avg_cost, 0.04, 0.001
    end

    test "returns :default when insufficient data" do
      insert_metric(%{scope_tier: "campaign", cost_usd: 0.50})

      assert {:default, "campaign"} =
               Learning.recommend_tier(%{task_description: "refactor module", file_matches: 20})
    end

    test "infers correct tiers from file_matches" do
      # quick: <= 3 files
      assert {:default, "quick"} =
               Learning.recommend_tier(%{task_description: "x", file_matches: 1})

      # session: 4-15 files
      assert {:default, "session"} =
               Learning.recommend_tier(%{task_description: "x", file_matches: 5})

      # campaign: > 15 files
      assert {:default, "campaign"} =
               Learning.recommend_tier(%{task_description: "x", file_matches: 16})

      # campaign: large
      assert {:default, "campaign"} =
               Learning.recommend_tier(%{task_description: "x", file_matches: 25})
    end

    test "old records without scope_tier do not break queries" do
      # Insert records without scope_tier
      for _ <- 1..10 do
        insert_metric(%{cost_usd: 0.10})
      end

      # Should return :default since none of the old records have scope_tier
      assert {:default, "session"} =
               Learning.recommend_tier(%{task_description: "update helpers", file_matches: 4})
    end
  end

  # ── record_task_result/1 with scope fields ─────────────────────────

  describe "record_task_result/1 with scope fields" do
    test "accepts scope_tier and files_touched" do
      assert {:ok, metric} =
               Learning.record_task_result(%{
                 team_id: "team-1",
                 agent_name: "coder",
                 model: "anthropic:claude-sonnet-4-6",
                 task_type: "code_edit",
                 success: true,
                 scope_tier: "session",
                 files_touched: 5
               })

      assert metric.scope_tier == "session"
      assert metric.files_touched == 5
    end

    test "scope fields are optional and default to nil" do
      assert {:ok, metric} =
               Learning.record_task_result(%{
                 team_id: "team-1",
                 agent_name: "coder",
                 model: "anthropic:claude-sonnet-4-6",
                 task_type: "code_edit",
                 success: true
               })

      assert metric.scope_tier == nil
      assert metric.files_touched == nil
    end
  end
end
