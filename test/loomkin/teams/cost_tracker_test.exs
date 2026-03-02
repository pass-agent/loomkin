defmodule Loomkin.Teams.CostTrackerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.CostTracker

  setup do
    CostTracker.init()
    team_id = "ct-test-#{:erlang.unique_integer([:positive])}"
    %{team_id: team_id}
  end

  # ── record_usage/3 ───────────────────────────────────────────────────

  describe "record_usage/3" do
    test "records usage for an agent", %{team_id: team_id} do
      :ok =
        CostTracker.record_usage(team_id, "coder", %{
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01,
          model: "zai:glm-5"
        })

      usage = CostTracker.get_agent_usage(team_id, "coder")
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.cost == 0.01
      assert usage.requests == 1
      assert usage.last_model == "zai:glm-5"
    end

    test "accumulates multiple usage records", %{team_id: team_id} do
      :ok =
        CostTracker.record_usage(team_id, "coder", %{
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01,
          model: "zai:glm-5"
        })

      :ok =
        CostTracker.record_usage(team_id, "coder", %{
          input_tokens: 200,
          output_tokens: 100,
          cost: 0.02,
          model: "anthropic:claude-sonnet-4-6"
        })

      usage = CostTracker.get_agent_usage(team_id, "coder")
      assert usage.input_tokens == 300
      assert usage.output_tokens == 150
      assert usage.cost == 0.03
      assert usage.requests == 2
      assert usage.last_model == "anthropic:claude-sonnet-4-6"
    end

    test "handles partial usage maps", %{team_id: team_id} do
      :ok = CostTracker.record_usage(team_id, "coder", %{cost: 0.05})

      usage = CostTracker.get_agent_usage(team_id, "coder")
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.cost == 0.05
      assert usage.requests == 1
    end

    test "auto-calculates cost from model and tokens when cost is nil", %{team_id: team_id} do
      :ok =
        CostTracker.record_usage(team_id, "coder", %{
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
          model: "anthropic:claude-sonnet-4-6"
        })

      usage = CostTracker.get_agent_usage(team_id, "coder")
      # 1M input at $3/M + 1M output at $15/M = $18.00
      assert_in_delta usage.cost, 18.0, 0.01
    end
  end

  # ── get_agent_usage/2 ────────────────────────────────────────────────

  describe "get_agent_usage/2" do
    test "returns defaults for unknown agent", %{team_id: team_id} do
      usage = CostTracker.get_agent_usage(team_id, "nonexistent")
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.cost == 0
      assert usage.requests == 0
      assert usage.last_model == nil
    end

    test "returns correct totals after multiple records", %{team_id: team_id} do
      for i <- 1..5 do
        :ok =
          CostTracker.record_usage(team_id, "coder", %{
            input_tokens: 100 * i,
            output_tokens: 50 * i,
            cost: 0.01 * i,
            model: "zai:glm-5"
          })
      end

      usage = CostTracker.get_agent_usage(team_id, "coder")
      # sum of 100*i for i=1..5 = 1500
      assert usage.input_tokens == 1500
      # sum of 50*i for i=1..5 = 750
      assert usage.output_tokens == 750
      assert usage.requests == 5
      assert_in_delta usage.cost, 0.15, 0.001
    end
  end

  # ── get_team_usage/1 ─────────────────────────────────────────────────

  describe "get_team_usage/1" do
    test "returns per-agent breakdown", %{team_id: team_id} do
      :ok =
        CostTracker.record_usage(team_id, "coder", %{
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01,
          model: "zai:glm-5"
        })

      :ok =
        CostTracker.record_usage(team_id, "researcher", %{
          input_tokens: 200,
          output_tokens: 80,
          cost: 0.02,
          model: "zai:glm-5"
        })

      team = CostTracker.get_team_usage(team_id)
      assert map_size(team) == 2
      assert team["coder"].cost == 0.01
      assert team["researcher"].cost == 0.02
    end

    test "returns empty map for unknown team" do
      assert %{} = CostTracker.get_team_usage("nonexistent-team-xyz")
    end

    test "does not leak data between teams" do
      team_a = "team-a-#{:erlang.unique_integer([:positive])}"
      team_b = "team-b-#{:erlang.unique_integer([:positive])}"

      :ok = CostTracker.record_usage(team_a, "coder", %{cost: 0.10})
      :ok = CostTracker.record_usage(team_b, "coder", %{cost: 0.20})

      assert CostTracker.get_team_usage(team_a)["coder"].cost == 0.10
      assert CostTracker.get_team_usage(team_b)["coder"].cost == 0.20

      CostTracker.reset_team(team_a)
      CostTracker.reset_team(team_b)
    end
  end

  # ── record_call/3 & get_call_history/2 ───────────────────────────────

  describe "record_call/3" do
    test "stores individual call details", %{team_id: team_id} do
      :ok =
        CostTracker.record_call(team_id, "coder", %{
          model: "zai:glm-5",
          input_tokens: 500,
          output_tokens: 200,
          cost: 0.005,
          task_id: "task-1",
          duration_ms: 1200
        })

      calls = CostTracker.get_call_history(team_id, "coder")
      assert length(calls) == 1

      [call] = calls
      assert call.model == "zai:glm-5"
      assert call.input_tokens == 500
      assert call.output_tokens == 200
      assert call.cost == 0.005
      assert call.task_id == "task-1"
      assert call.duration_ms == 1200
      assert %DateTime{} = call.timestamp
    end

    test "auto-calculates cost when not provided", %{team_id: team_id} do
      :ok =
        CostTracker.record_call(team_id, "coder", %{
          model: "anthropic:claude-sonnet-4-6",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        })

      [call] = CostTracker.get_call_history(team_id, "coder")
      # $3 input + $15 output = $18
      assert_in_delta call.cost, 18.0, 0.01
    end

    test "sets timestamp automatically if not provided", %{team_id: team_id} do
      :ok =
        CostTracker.record_call(team_id, "coder", %{
          model: "zai:glm-5",
          input_tokens: 100,
          output_tokens: 50
        })

      [call] = CostTracker.get_call_history(team_id, "coder")
      assert %DateTime{} = call.timestamp
    end
  end

  describe "get_call_history/2" do
    test "returns calls in reverse chronological order (newest first)", %{team_id: team_id} do
      for i <- 1..3 do
        :ok =
          CostTracker.record_call(team_id, "coder", %{
            model: "zai:glm-5",
            input_tokens: i * 100,
            output_tokens: i * 50,
            cost: i * 0.01,
            task_id: "task-#{i}"
          })
      end

      calls = CostTracker.get_call_history(team_id, "coder")
      assert length(calls) == 3

      # Newest first (prepended to list)
      [newest, middle, oldest] = calls
      assert newest.task_id == "task-3"
      assert middle.task_id == "task-2"
      assert oldest.task_id == "task-1"
    end

    test "returns empty list for unknown agent", %{team_id: team_id} do
      assert [] = CostTracker.get_call_history(team_id, "nonexistent")
    end
  end

  # ── record_escalation/4 & list_escalations/1 ─────────────────────────

  describe "record_escalation/4" do
    test "records an escalation event", %{team_id: team_id} do
      :ok =
        CostTracker.record_escalation(
          team_id,
          "coder",
          "zai:glm-5",
          "anthropic:claude-sonnet-4-6"
        )

      escalations = CostTracker.list_escalations(team_id)
      assert length(escalations) == 1

      [event] = escalations
      assert event.agent == "coder"
      assert event.from == "zai:glm-5"
      assert event.to == "anthropic:claude-sonnet-4-6"
      assert %DateTime{} = event.at
    end

    test "records multiple escalation events in chronological order", %{team_id: team_id} do
      :ok = CostTracker.record_escalation(team_id, "coder", "zai:glm-4.5", "zai:glm-5")

      :ok =
        CostTracker.record_escalation(
          team_id,
          "coder",
          "zai:glm-5",
          "anthropic:claude-sonnet-4-6"
        )

      escalations = CostTracker.list_escalations(team_id)
      assert length(escalations) == 2

      [first, second] = escalations
      assert first.from == "zai:glm-4.5"
      assert second.from == "zai:glm-5"
    end
  end

  describe "list_escalations/1" do
    test "returns empty list for unknown team" do
      assert [] = CostTracker.list_escalations("nonexistent-team-xyz")
    end
  end

  # ── reset_team/1 ────────────────────────────────────────────────────

  describe "reset_team/1" do
    test "clears agent usage, call history, and escalations", %{team_id: team_id} do
      :ok = CostTracker.record_usage(team_id, "coder", %{cost: 1.00})

      :ok =
        CostTracker.record_call(team_id, "coder", %{
          model: "zai:glm-5",
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })

      :ok =
        CostTracker.record_escalation(
          team_id,
          "coder",
          "zai:glm-5",
          "anthropic:claude-sonnet-4-6"
        )

      :ok = CostTracker.reset_team(team_id)

      assert %{} = CostTracker.get_team_usage(team_id)
      assert [] = CostTracker.get_call_history(team_id, "coder")
      assert [] = CostTracker.list_escalations(team_id)
    end

    test "is idempotent for unknown teams" do
      assert :ok = CostTracker.reset_team("nonexistent")
    end

    test "does not affect other teams" do
      team_x = "team-x-#{:erlang.unique_integer([:positive])}"
      team_y = "team-y-#{:erlang.unique_integer([:positive])}"

      :ok = CostTracker.record_usage(team_x, "coder", %{cost: 0.50})
      :ok = CostTracker.record_usage(team_y, "coder", %{cost: 0.75})

      :ok =
        CostTracker.record_call(team_y, "coder", %{
          model: "zai:glm-5",
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })

      :ok = CostTracker.reset_team(team_x)

      assert %{} = CostTracker.get_team_usage(team_x)
      team_y_usage = CostTracker.get_team_usage(team_y)
      assert team_y_usage["coder"].cost == 0.75
      assert length(CostTracker.get_call_history(team_y, "coder")) == 1

      CostTracker.reset_team(team_y)
    end
  end
end
