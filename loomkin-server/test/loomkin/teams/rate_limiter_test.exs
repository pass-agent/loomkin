defmodule Loomkin.Teams.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.RateLimiter

  # The RateLimiter is started by the application supervisor as a singleton.
  # We replace its state before each test to get a clean starting point.

  setup do
    # Reset to fresh state via :sys.replace_state
    :sys.replace_state(RateLimiter, fn _old ->
      # Reproduce the initial state from init/1
      now = System.monotonic_time(:millisecond)

      buckets =
        Map.new(
          %{
            "anthropic" => %{max: 80_000, refill_rate: 80_000},
            "openai" => %{max: 90_000, refill_rate: 90_000},
            "google" => %{max: 60_000, refill_rate: 60_000}
          },
          fn {provider, config} ->
            {provider,
             %{
               tokens: config.max,
               max: config.max,
               refill_rate: config.refill_rate,
               last_refill: now
             }}
          end
        )

      %{buckets: buckets, teams: %{}}
    end)

    :ok
  end

  describe "token bucket - acquire/2" do
    test "acquire succeeds when tokens are available" do
      assert :ok = RateLimiter.acquire("anthropic", 1_000)
    end

    test "acquire succeeds for unknown provider using default bucket" do
      assert :ok = RateLimiter.acquire("some_new_provider", 1_000)
    end

    test "acquire returns {:wait, ms} when bucket is exhausted" do
      # Anthropic bucket has 80K tokens. Drain it.
      assert :ok = RateLimiter.acquire("anthropic", 80_000)

      # Next request should be told to wait
      assert {:wait, ms} = RateLimiter.acquire("anthropic", 1_000)
      assert is_integer(ms)
      assert ms > 0
    end

    test "acquire deducts tokens from the correct provider" do
      # Drain anthropic
      assert :ok = RateLimiter.acquire("anthropic", 80_000)
      assert {:wait, _} = RateLimiter.acquire("anthropic", 1)

      # OpenAI should still be full
      assert :ok = RateLimiter.acquire("openai", 1_000)
    end

    test "acquire handles partial depletion" do
      # Use 70K of 80K anthropic tokens
      assert :ok = RateLimiter.acquire("anthropic", 70_000)

      # 10K remaining, requesting 5K should succeed
      assert :ok = RateLimiter.acquire("anthropic", 5_000)

      # 5K remaining, requesting 10K should fail
      assert {:wait, _ms} = RateLimiter.acquire("anthropic", 10_000)
    end
  end

  describe "token bucket - refill" do
    test "tokens refill over time" do
      # Drain the bucket
      assert :ok = RateLimiter.acquire("anthropic", 80_000)
      assert {:wait, _} = RateLimiter.acquire("anthropic", 1)

      # Manually manipulate the state to simulate time passing
      # We'll set last_refill to 30 seconds ago (half a minute = half refill)
      state = :sys.get_state(RateLimiter)
      bucket = state.buckets["anthropic"]
      # Set last_refill to 60 seconds ago = full refill (80K tokens/min)
      old_bucket = %{bucket | last_refill: bucket.last_refill - 60_000}
      new_state = put_in(state, [:buckets, "anthropic"], old_bucket)
      :sys.replace_state(RateLimiter, fn _ -> new_state end)

      # Now acquire should succeed again
      assert :ok = RateLimiter.acquire("anthropic", 1_000)
    end
  end

  describe "budget tracking - record_usage/3" do
    test "record_usage accumulates cost and tokens" do
      assert :ok = RateLimiter.record_usage("team-1", "coder", %{tokens: 500, cost: 0.01})
      assert :ok = RateLimiter.record_usage("team-1", "coder", %{tokens: 300, cost: 0.02})

      budget = RateLimiter.get_agent_budget("team-1", "coder")
      assert budget.spent == 0.03
      assert budget.tokens_used == 800
    end

    test "record_usage tracks per-agent within a team" do
      assert :ok = RateLimiter.record_usage("team-1", "coder", %{tokens: 500, cost: 0.10})
      assert :ok = RateLimiter.record_usage("team-1", "researcher", %{tokens: 200, cost: 0.05})

      coder = RateLimiter.get_agent_budget("team-1", "coder")
      assert coder.spent == 0.10
      assert coder.tokens_used == 500

      researcher = RateLimiter.get_agent_budget("team-1", "researcher")
      assert researcher.spent == 0.05
      assert researcher.tokens_used == 200
    end

    test "record_usage aggregates at team level" do
      assert :ok = RateLimiter.record_usage("team-1", "coder", %{tokens: 500, cost: 0.10})
      assert :ok = RateLimiter.record_usage("team-1", "researcher", %{tokens: 200, cost: 0.05})

      budget = RateLimiter.get_budget("team-1")
      assert_in_delta budget.spent, 0.15, 0.001
      assert_in_delta budget.remaining, budget.limit - 0.15, 0.001
    end
  end

  describe "get_budget/1" do
    test "returns budget status for a team" do
      RateLimiter.record_usage("team-1", "coder", %{tokens: 100, cost: 0.50})

      budget = RateLimiter.get_budget("team-1")
      assert budget.spent == 0.50
      assert budget.limit == 5.00
      assert budget.remaining == 4.50
      assert is_map(budget.agents)
      assert budget.agents["coder"].spent == 0.50
    end

    test "returns defaults for unknown team" do
      budget = RateLimiter.get_budget("nonexistent-team")
      assert budget.spent == 0.0
      assert budget.limit == 5.00
      assert budget.remaining == 5.00
      assert budget.agents == %{}
    end
  end

  describe "get_agent_budget/2" do
    test "returns budget status for a specific agent" do
      RateLimiter.record_usage("team-1", "coder", %{tokens: 1000, cost: 0.25})

      agent = RateLimiter.get_agent_budget("team-1", "coder")
      assert agent.spent == 0.25
      assert agent.limit == 1.00
      assert agent.remaining == 0.75
      assert agent.tokens_used == 1000
    end

    test "returns defaults for unknown agent" do
      agent = RateLimiter.get_agent_budget("team-1", "unknown-agent")
      assert agent.spent == 0.0
      assert agent.limit == 1.00
      assert agent.remaining == 1.00
      assert agent.tokens_used == 0
    end
  end

  describe "reset_team/1" do
    test "clears team budget data" do
      RateLimiter.record_usage("team-1", "coder", %{tokens: 500, cost: 1.00})

      budget = RateLimiter.get_budget("team-1")
      assert budget.spent == 1.00

      assert :ok = RateLimiter.reset_team("team-1")

      # After reset, team starts fresh
      budget = RateLimiter.get_budget("team-1")
      assert budget.spent == 0.0
      assert budget.agents == %{}
    end

    test "reset_team is idempotent for unknown teams" do
      assert :ok = RateLimiter.reset_team("nonexistent")
    end
  end

  describe "concurrent access" do
    test "multiple acquire calls don't race" do
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            RateLimiter.acquire("anthropic", 4_000)
          end)
        end

      results = Task.await_many(tasks)

      # All 20 requests of 4K = 80K total, exactly exhausting the bucket.
      # All should succeed since GenServer serializes calls.
      ok_count = Enum.count(results, &(&1 == :ok))
      assert ok_count == 20
    end

    test "concurrent record_usage calls accumulate correctly" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            RateLimiter.record_usage("team-concurrent", "agent-#{rem(i, 3)}", %{
              tokens: 100,
              cost: 0.01
            })
          end)
        end

      Task.await_many(tasks)

      budget = RateLimiter.get_budget("team-concurrent")
      assert_in_delta budget.spent, 0.10, 0.001
    end
  end

  describe "default config" do
    test "uses default budget limits when no config is set" do
      budget = RateLimiter.get_budget("fresh-team")
      assert budget.limit == 5.00

      agent = RateLimiter.get_agent_budget("fresh-team", "agent-1")
      assert agent.limit == 1.00
    end

    test "default provider buckets have expected capacities" do
      # Request more than max so the bucket is guaranteed empty even after
      # wall-clock refill between the two GenServer.call round-trips.
      # (refill_rate of 80K/min ≈ 1.3 tokens/ms, so a few ms adds tokens.)
      overshoot = 500

      # Anthropic: 80K
      assert :ok = RateLimiter.acquire("anthropic", 80_000)
      assert {:wait, _} = RateLimiter.acquire("anthropic", overshoot)

      # OpenAI: 90K (separate bucket, still full)
      assert :ok = RateLimiter.acquire("openai", 90_000)
      assert {:wait, _} = RateLimiter.acquire("openai", overshoot)

      # Google: 60K
      assert :ok = RateLimiter.acquire("google", 60_000)
      assert {:wait, _} = RateLimiter.acquire("google", overshoot)
    end
  end
end
