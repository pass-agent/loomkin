defmodule Loomkin.Teams.Pricing do
  @moduledoc "Provider-specific token pricing for cost calculation."

  # Prices per million tokens
  @pricing %{
    "zai:glm-4.5" => %{input: 0.55, output: 2.19},
    "zai:glm-5" => %{input: 0.95, output: 3.79},
    "anthropic:claude-sonnet-4-6" => %{input: 3.00, output: 15.00},
    "anthropic:claude-opus-4-6" => %{input: 5.00, output: 25.00},
    "anthropic:claude-haiku-4-5" => %{input: 0.80, output: 4.00}
  }

  @doc "Calculate the cost in USD for a given model and token counts."
  @spec calculate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(model, input_tokens, output_tokens) do
    case price_for_model(model) do
      nil ->
        0.0

      %{input: input_price, output: output_price} ->
        input_cost = input_tokens / 1_000_000 * input_price
        output_cost = output_tokens / 1_000_000 * output_price
        Float.round(input_cost + output_cost, 8)
    end
  end

  @doc "Return the pricing map for a model, or nil if unknown."
  @spec price_for_model(String.t()) :: %{input: float(), output: float()} | nil
  def price_for_model(model) do
    Map.get(@pricing, model)
  end

  @doc """
  Estimate cost before a call, given a total estimated token count.
  Splits 60% input / 40% output.
  """
  @spec estimate_cost(String.t(), non_neg_integer()) :: float()
  def estimate_cost(model, estimated_tokens) do
    input_tokens = round(estimated_tokens * 0.6)
    output_tokens = round(estimated_tokens * 0.4)
    calculate_cost(model, input_tokens, output_tokens)
  end
end
