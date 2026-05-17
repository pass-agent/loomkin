defmodule Loomkin.Orchestration.RetryLadderTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.RetryLadder

  describe "default 5-attempt ladder" do
    test "attempt 1 is the no-override baseline" do
      knobs = RetryLadder.knobs(:gate, 1)
      assert knobs.strategy == :default
      assert knobs.model == nil
      assert knobs.reasoning_effort == nil
      assert knobs.include_prior_failure == false
      assert knobs.include_primed_facts == false
    end

    test "attempt 2 prepends the prior verdict" do
      knobs = RetryLadder.knobs(:gate, 2)
      assert knobs.strategy == :with_prior_failure
      assert knobs.include_prior_failure == true
    end

    test "attempt 3 boosts reasoning effort" do
      knobs = RetryLadder.knobs(:gate, 3)
      assert knobs.strategy == :boost_effort
      assert knobs.reasoning_effort == :high
    end

    test "attempt 4 swaps to the next model in the pool" do
      knobs = RetryLadder.knobs(:gate, 4)
      assert knobs.strategy == :swap_model
      assert knobs.model == :next_in_pool
    end

    test "attempt 5 primes with curator facts" do
      knobs = RetryLadder.knobs(:gate, 5)
      assert knobs.strategy == :prime_with_facts
      assert knobs.include_primed_facts == true
    end

    test "attempt 6 is :escalate (cap+1)" do
      assert RetryLadder.knobs(:gate, 6) == :escalate
      assert RetryLadder.knobs(:work_unit, 6) == :escalate
    end

    test "work_unit scope mirrors the gate ladder by default" do
      for attempt <- 1..5 do
        assert RetryLadder.knobs(:gate, attempt) == RetryLadder.knobs(:work_unit, attempt)
      end
    end

    test "max_attempts/1 returns 5 for both scopes" do
      assert RetryLadder.max_attempts(:gate) == 5
      assert RetryLadder.max_attempts(:work_unit) == 5
    end

    test "default_ladder/0 exposes the five canonical rungs" do
      ladder = RetryLadder.default_ladder()
      assert length(ladder) == 5

      assert Enum.map(ladder, & &1.strategy) == [
               :default,
               :with_prior_failure,
               :boost_effort,
               :swap_model,
               :prime_with_facts
             ]
    end
  end

  describe "config-driven overrides" do
    setup do
      original = Application.get_env(:loomkin, Loomkin.Orchestration, [])
      on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, original) end)
      :ok
    end

    test "a shorter gate ladder shrinks max_attempts and escalates sooner" do
      custom = [
        %{
          strategy: :default,
          model: nil,
          reasoning_effort: nil,
          include_prior_failure: false,
          include_primed_facts: false
        },
        %{
          strategy: :boost_effort,
          model: "claude-haiku",
          reasoning_effort: :high,
          include_prior_failure: true,
          include_primed_facts: false
        }
      ]

      Application.put_env(:loomkin, Loomkin.Orchestration, retry_ladder: [gate: custom])

      assert RetryLadder.max_attempts(:gate) == 2
      assert RetryLadder.knobs(:gate, 2).model == "claude-haiku"
      assert RetryLadder.knobs(:gate, 3) == :escalate

      # work_unit untouched
      assert RetryLadder.max_attempts(:work_unit) == 5
      assert RetryLadder.knobs(:work_unit, 1).strategy == :default
    end

    test "empty override list falls back to the default ladder" do
      Application.put_env(:loomkin, Loomkin.Orchestration, retry_ladder: [gate: []])
      assert RetryLadder.max_attempts(:gate) == 5
    end
  end
end
