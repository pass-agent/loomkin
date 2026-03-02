defmodule Loomkin.Teams.PricingTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Pricing

  # ── calculate_cost/3 ──────────────────────────────────────────────────

  describe "calculate_cost/3" do
    test "calculates cost for zai:glm-4.5" do
      # 1000 input tokens at $0.55/M = 0.00055
      # 500 output tokens at $2.19/M = 0.001095
      cost = Pricing.calculate_cost("zai:glm-4.5", 1_000, 500)
      assert_in_delta cost, 0.00055 + 0.001095, 0.00000001
    end

    test "calculates cost for zai:glm-5" do
      # 1000 input at $0.95/M = 0.00095
      # 500 output at $3.79/M = 0.001895
      cost = Pricing.calculate_cost("zai:glm-5", 1_000, 500)
      assert_in_delta cost, 0.00095 + 0.001895, 0.00000001
    end

    test "calculates cost for anthropic:claude-sonnet-4-6" do
      # 1000 input at $3.00/M = 0.003
      # 500 output at $15.00/M = 0.0075
      cost = Pricing.calculate_cost("anthropic:claude-sonnet-4-6", 1_000, 500)
      assert_in_delta cost, 0.003 + 0.0075, 0.00000001
    end

    test "calculates cost for anthropic:claude-opus-4-6" do
      # 1000 input at $5.00/M = 0.005
      # 500 output at $25.00/M = 0.0125
      cost = Pricing.calculate_cost("anthropic:claude-opus-4-6", 1_000, 500)
      assert_in_delta cost, 0.005 + 0.0125, 0.00000001
    end

    test "calculates cost for anthropic:claude-haiku-4-5" do
      # 1000 input at $0.80/M = 0.0008
      # 500 output at $4.00/M = 0.002
      cost = Pricing.calculate_cost("anthropic:claude-haiku-4-5", 1_000, 500)
      assert_in_delta cost, 0.0008 + 0.002, 0.00000001
    end

    test "returns 0.0 for unknown model" do
      assert 0.0 == Pricing.calculate_cost("unknown:model", 1_000, 500)
    end

    test "returns 0.0 when zero tokens" do
      assert 0.0 == Pricing.calculate_cost("zai:glm-5", 0, 0)
    end

    test "handles large token counts" do
      # 1M input at $3.00/M = $3.00
      # 1M output at $15.00/M = $15.00
      cost = Pricing.calculate_cost("anthropic:claude-sonnet-4-6", 1_000_000, 1_000_000)
      assert_in_delta cost, 18.0, 0.00000001
    end
  end

  # ── price_for_model/1 ────────────────────────────────────────────────

  describe "price_for_model/1" do
    test "returns pricing map for known models" do
      assert %{input: 0.55, output: 2.19} = Pricing.price_for_model("zai:glm-4.5")
      assert %{input: 0.95, output: 3.79} = Pricing.price_for_model("zai:glm-5")
      assert %{input: 3.00, output: 15.00} = Pricing.price_for_model("anthropic:claude-sonnet-4-6")
      assert %{input: 5.00, output: 25.00} = Pricing.price_for_model("anthropic:claude-opus-4-6")
      assert %{input: 0.80, output: 4.00} = Pricing.price_for_model("anthropic:claude-haiku-4-5")
    end

    test "returns nil for unknown model" do
      assert nil == Pricing.price_for_model("unknown:model")
    end
  end

  # ── estimate_cost/2 ──────────────────────────────────────────────────

  describe "estimate_cost/2" do
    test "returns a reasonable estimate (60/40 split)" do
      # 1000 tokens total -> 600 input, 400 output
      # glm-5: 600 * 0.95/1M + 400 * 3.79/1M
      estimate = Pricing.estimate_cost("zai:glm-5", 1_000)
      expected = 600 / 1_000_000 * 0.95 + 400 / 1_000_000 * 3.79
      assert_in_delta estimate, expected, 0.00000001
    end

    test "returns 0.0 for unknown model" do
      assert 0.0 == Pricing.estimate_cost("unknown:model", 1_000)
    end

    test "returns 0.0 for zero tokens" do
      assert 0.0 == Pricing.estimate_cost("zai:glm-5", 0)
    end

    test "estimate is always less than all-output cost" do
      # The estimate (60/40 split) should cost less than if all tokens were output
      # since output is always more expensive than input
      model = "anthropic:claude-opus-4-6"
      tokens = 10_000

      estimate = Pricing.estimate_cost(model, tokens)
      all_output = Pricing.calculate_cost(model, 0, tokens)

      assert estimate < all_output
    end
  end
end
