defmodule Loomkin.Teams.Pricing do
  @moduledoc """
  Provider-specific token pricing for cost calculation.

  When a provider is accessed via OAuth (subscription), costs are $0.00
  since usage is covered by the subscription. Token counts are still
  tracked for analytics purposes.
  """

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
    if subscription_model?(model) do
      0.0
    else
      case price_for_model(model) do
        nil ->
          0.0

        %{input: input_price, output: output_price} ->
          input_cost = input_tokens / 1_000_000 * input_price
          output_cost = output_tokens / 1_000_000 * output_price
          Float.round(input_cost + output_cost, 8)
      end
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

  alias Loomkin.Auth.ProviderRegistry

  @doc """
  Returns true if the model is being accessed via a subscription (OAuth),
  meaning there is no per-token cost.

  Checks if the model string starts with an OAuth provider prefix
  (e.g., `"anthropic_oauth:"`) or if the provider has an active OAuth
  connection and no API key configured.
  """
  @spec subscription_model?(String.t()) :: boolean()
  def subscription_model?(model) when is_binary(model) do
    cond do
      # Explicit OAuth provider prefix (e.g., "anthropic_oauth:...")
      ProviderRegistry.oauth_prefix?(model) ->
        true

      # Standard provider prefix with active OAuth and no API key
      ProviderRegistry.oauth_base_prefix?(model) ->
        [provider_str | _] = String.split(model, ":", parts: 2)

        case ProviderRegistry.get(String.to_existing_atom(provider_str)) do
          nil ->
            false

          entry ->
            Loomkin.LLM.oauth_active?(provider_str) and
              not api_key_present?(entry.env_var)
        end

      true ->
        false
    end
  rescue
    _ -> false
  end

  def subscription_model?(_), do: false

  defp api_key_present?(env_var) do
    case System.get_env(env_var) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
