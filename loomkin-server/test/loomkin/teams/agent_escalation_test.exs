defmodule Loomkin.Teams.AgentEscalationTest do
  @moduledoc """
  Integration-style tests verifying that ModelRouter failure tracking,
  should_escalate?, and escalate work together correctly in sequence —
  the core escalation flow used by Agent.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{CostTracker, ModelRouter}

  setup do
    ModelRouter.init()
    CostTracker.init()

    team_id = "esc-test-#{:erlang.unique_integer([:positive])}"
    agent_name = "coder"
    task_id = "task-#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      ModelRouter.reset_tracking(team_id)
      CostTracker.reset_team(team_id)
      # Clean up any escalation config set during tests
      try do
        Loomkin.Config.put(:teams, %{})
      rescue
        _ -> :ok
      end
    end)

    %{team_id: team_id, agent_name: agent_name, task_id: task_id}
  end

  describe "escalation flow: failures -> should_escalate? -> escalate" do
    test "single failure does not trigger escalation", ctx do
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)

      refute ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)
    end

    test "two failures trigger escalation", ctx do
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)

      assert ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)
    end

    test "escalate returns :disabled without configured escalation chain", _ctx do
      # Under 5.7 opt-in behavior, escalate returns :disabled when no
      # [teams.models].escalation is configured
      assert :disabled = ModelRouter.escalate("zai:glm-4.5")
      assert :disabled = ModelRouter.escalate("zai:glm-5")
      assert :disabled = ModelRouter.escalate("anthropic:claude-sonnet-4-6")
    end

    test "full escalation sequence with configured chain: failures -> check -> escalate -> track",
         ctx do
      starting_model = "zai:glm-4.5"

      chain = [
        "zai:glm-4.5",
        "zai:glm-5",
        "anthropic:claude-sonnet-4-6",
        "anthropic:claude-opus-4-6"
      ]

      # Configure escalation chain
      Loomkin.Config.put(:teams, %{models: %{escalation: chain}})

      # First failure — no escalation yet
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      refute ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)

      # Second failure — escalation triggered
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      assert ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)

      # Escalate from grunt to standard
      assert {:ok, next_model} = ModelRouter.escalate(starting_model)
      assert next_model == "zai:glm-5"

      # Record escalation in CostTracker
      :ok =
        CostTracker.record_escalation(
          ctx.team_id,
          ctx.agent_name,
          starting_model,
          next_model
        )

      escalations = CostTracker.list_escalations(ctx.team_id)
      assert length(escalations) == 1
      assert hd(escalations).from == "zai:glm-4.5"
      assert hd(escalations).to == "zai:glm-5"
    end

    test "full chain escalation through all tiers with configured escalation", ctx do
      chain = [
        "zai:glm-4.5",
        "zai:glm-5",
        "anthropic:claude-sonnet-4-6",
        "anthropic:claude-opus-4-6"
      ]

      # Configure escalation chain
      Loomkin.Config.put(:teams, %{models: %{escalation: chain}})

      # Walk through the full escalation chain
      Enum.chunk_every(chain, 2, 1, :discard)
      |> Enum.each(fn [current, expected_next] ->
        assert {:ok, ^expected_next} = ModelRouter.escalate(current)

        CostTracker.record_escalation(ctx.team_id, ctx.agent_name, current, expected_next)
      end)

      # Architect is the top — no further escalation
      assert :max_reached = ModelRouter.escalate("anthropic:claude-opus-4-6")

      # Verify all escalation events were tracked
      escalations = CostTracker.list_escalations(ctx.team_id)
      assert length(escalations) == 3

      [e1, e2, e3] = escalations
      assert e1.from == "zai:glm-4.5" and e1.to == "zai:glm-5"
      assert e2.from == "zai:glm-5" and e2.to == "anthropic:claude-sonnet-4-6"
      assert e3.from == "anthropic:claude-sonnet-4-6" and e3.to == "anthropic:claude-opus-4-6"
    end

    test "success after escalation records correctly with configured chain", ctx do
      current_model = "zai:glm-5"

      chain = [
        "zai:glm-4.5",
        "zai:glm-5",
        "anthropic:claude-sonnet-4-6",
        "anthropic:claude-opus-4-6"
      ]

      # Configure escalation chain
      Loomkin.Config.put(:teams, %{models: %{escalation: chain}})

      # Fail twice to trigger escalation
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      assert ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)

      # Escalate
      {:ok, next_model} = ModelRouter.escalate(current_model)
      assert next_model == "anthropic:claude-sonnet-4-6"

      CostTracker.record_escalation(ctx.team_id, ctx.agent_name, current_model, next_model)

      # Success on escalated model
      :ok = ModelRouter.record_success(ctx.team_id, ctx.agent_name, ctx.task_id, next_model)

      # Record the usage
      :ok =
        CostTracker.record_usage(ctx.team_id, ctx.agent_name, %{
          input_tokens: 500,
          output_tokens: 200,
          model: next_model
        })

      :ok =
        CostTracker.record_call(ctx.team_id, ctx.agent_name, %{
          model: next_model,
          input_tokens: 500,
          output_tokens: 200,
          task_id: ctx.task_id
        })

      # Verify usage and escalation records
      usage = CostTracker.get_agent_usage(ctx.team_id, ctx.agent_name)
      assert usage.last_model == "anthropic:claude-sonnet-4-6"
      assert usage.input_tokens == 500
      assert usage.requests == 1

      calls = CostTracker.get_call_history(ctx.team_id, ctx.agent_name)
      assert length(calls) == 1
      assert hd(calls).model == "anthropic:claude-sonnet-4-6"

      escalations = CostTracker.list_escalations(ctx.team_id)
      assert length(escalations) == 1
    end

    test "cost tracking accumulates across escalation attempts", ctx do
      # First attempt with glm-5
      :ok =
        CostTracker.record_usage(ctx.team_id, ctx.agent_name, %{
          input_tokens: 1000,
          output_tokens: 500,
          cost: 0.01,
          model: "zai:glm-5"
        })

      # Escalate to sonnet, second attempt
      :ok =
        CostTracker.record_usage(ctx.team_id, ctx.agent_name, %{
          input_tokens: 1000,
          output_tokens: 500,
          cost: 0.05,
          model: "anthropic:claude-sonnet-4-6"
        })

      usage = CostTracker.get_agent_usage(ctx.team_id, ctx.agent_name)
      assert usage.requests == 2
      assert usage.input_tokens == 2000
      assert usage.output_tokens == 1000
      assert_in_delta usage.cost, 0.06, 0.001
      assert usage.last_model == "anthropic:claude-sonnet-4-6"
    end
  end

  describe "reset clears everything" do
    test "reset_tracking + reset_team clears all data", ctx do
      # Create some data
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      :ok = ModelRouter.record_failure(ctx.team_id, ctx.agent_name, ctx.task_id)
      :ok = ModelRouter.record_success(ctx.team_id, ctx.agent_name, ctx.task_id, "zai:glm-5")

      :ok =
        CostTracker.record_usage(ctx.team_id, ctx.agent_name, %{cost: 1.0, model: "zai:glm-5"})

      :ok =
        CostTracker.record_call(ctx.team_id, ctx.agent_name, %{
          model: "zai:glm-5",
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })

      :ok =
        CostTracker.record_escalation(
          ctx.team_id,
          ctx.agent_name,
          "zai:glm-5",
          "anthropic:claude-sonnet-4-6"
        )

      # Reset both
      :ok = ModelRouter.reset_tracking(ctx.team_id)
      :ok = CostTracker.reset_team(ctx.team_id)

      # Verify everything is clean
      assert ModelRouter.get_failure_count(ctx.team_id, ctx.agent_name, ctx.task_id) == 0
      refute ModelRouter.should_escalate?(ctx.team_id, ctx.agent_name, ctx.task_id)
      assert %{} = CostTracker.get_team_usage(ctx.team_id)
      assert [] = CostTracker.get_call_history(ctx.team_id, ctx.agent_name)
      assert [] = CostTracker.list_escalations(ctx.team_id)
    end
  end
end
