defmodule Loomkin.Teams.PricingTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Pricing

  describe "calculate_cost/3" do
    test "calculates cost for zai:glm-4.5" do
      cost = Pricing.calculate_cost("zai:glm-4.5", 1_000, 500)
      assert_in_delta cost, 0.00055 + 0.001095, 0.00000001
    end

    test "calculates cost for zai:glm-5" do
      cost = Pricing.calculate_cost("zai:glm-5", 1_000, 500)
      assert_in_delta cost, 0.00095 + 0.001895, 0.00000001
    end

    test "calculates cost for anthropic:claude-sonnet-4-6" do
      cost = Pricing.calculate_cost("anthropic:claude-sonnet-4-6", 1_000, 500)
      assert_in_delta cost, 0.003 + 0.0075, 0.00000001
    end

    test "calculates cost for anthropic:claude-opus-4-6" do
      cost = Pricing.calculate_cost("anthropic:claude-opus-4-6", 1_000, 500)
      assert_in_delta cost, 0.005 + 0.0125, 0.00000001
    end

    test "calculates cost for anthropic:claude-haiku-4-5" do
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
      cost = Pricing.calculate_cost("anthropic:claude-sonnet-4-6", 1_000_000, 1_000_000)
      assert_in_delta cost, 18.0, 0.00000001
    end
  end

  describe "price_for_model/1" do
    test "returns pricing map for known models" do
      assert %{input: 0.55, output: 2.19} = Pricing.price_for_model("zai:glm-4.5")
      assert %{input: 0.95, output: 3.79} = Pricing.price_for_model("zai:glm-5")

      assert %{input: 3.00, output: 15.00} =
               Pricing.price_for_model("anthropic:claude-sonnet-4-6")

      assert %{input: 5.00, output: 25.00} = Pricing.price_for_model("anthropic:claude-opus-4-6")
      assert %{input: 0.80, output: 4.00} = Pricing.price_for_model("anthropic:claude-haiku-4-5")
    end

    test "returns nil for unknown model" do
      assert nil == Pricing.price_for_model("unknown:model")
    end
  end

  describe "estimate_cost/2" do
    test "returns a reasonable estimate (60/40 split)" do
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
      model = "anthropic:claude-opus-4-6"
      tokens = 10_000

      estimate = Pricing.estimate_cost(model, tokens)
      all_output = Pricing.calculate_cost(model, 0, tokens)

      assert estimate < all_output
    end
  end

  describe "subscription_model?/1" do
    test "returns true for all oauth-prefixed models" do
      assert Pricing.subscription_model?("anthropic_oauth:claude-sonnet-4-6")
      assert Pricing.subscription_model?("google_oauth:gemini-pro")
      assert Pricing.subscription_model?("openai_oauth:gpt-4o")
    end

    test "returns false for non-oauth model without active session" do
      refute Pricing.subscription_model?("zai:glm-5")
    end

    test "returns false for unknown model string" do
      refute Pricing.subscription_model?("completely_unknown:model")
    end

    test "returns false for non-string input" do
      refute Pricing.subscription_model?(nil)
      refute Pricing.subscription_model?(123)
    end
  end

  describe "calculate_cost/3 with subscription models" do
    test "returns 0.0 for all oauth-prefixed models (subscription)" do
      assert 0.0 == Pricing.calculate_cost("anthropic_oauth:claude-sonnet-4-6", 1_000, 500)
      assert 0.0 == Pricing.calculate_cost("google_oauth:gemini-pro", 1_000, 500)
      assert 0.0 == Pricing.calculate_cost("openai_oauth:gpt-4o", 1_000, 500)
    end
  end
end
