defmodule Loomkin.Orchestration.CostTracker.PricingTable do
  @moduledoc """
  Static lookup table of per-million-token prices (USD) for the models
  Loomkin's orchestration framework calls.

  Returns `{:ok, %{input_per_1m: Decimal, output_per_1m: Decimal}}` when a
  model is known, or `:error` when it is not. `CostTracker` records unknown
  models with `cost_usd: nil` so future analysis can backfill once this
  table is updated.

  Update these as providers change their pricing. The numbers below are
  documented approximations as of 2026-05; treat them as conservative
  estimates, not contracts.
  """

  @table %{
    "anthropic:claude-sonnet-4-5" => %{
      input_per_1m: Decimal.new("3.00"),
      output_per_1m: Decimal.new("15.00")
    },
    "anthropic:claude-haiku-4-5" => %{
      input_per_1m: Decimal.new("0.80"),
      output_per_1m: Decimal.new("4.00")
    },
    "anthropic:claude-opus-4-7" => %{
      input_per_1m: Decimal.new("15.00"),
      output_per_1m: Decimal.new("75.00")
    },
    "openai:gpt-4o-mini" => %{
      input_per_1m: Decimal.new("0.15"),
      output_per_1m: Decimal.new("0.60")
    },
    "openai:gpt-4o" => %{
      input_per_1m: Decimal.new("2.50"),
      output_per_1m: Decimal.new("10.00")
    },
    "google_oauth:gemini-2.5-flash" => %{
      input_per_1m: Decimal.new("0.075"),
      output_per_1m: Decimal.new("0.30")
    },
    "google:gemini-2.5-flash" => %{
      input_per_1m: Decimal.new("0.075"),
      output_per_1m: Decimal.new("0.30")
    }
  }

  @doc """
  Look up pricing for `model`. Returns `{:ok, %{input_per_1m, output_per_1m}}`
  or `:error`.

  An exact-key match is tried first, then a prefix match (so e.g.
  `"anthropic:claude-sonnet-4-5-20260101"` resolves to the
  `"anthropic:claude-sonnet-4-5"` row).
  """
  @spec lookup(String.t() | nil) ::
          {:ok, %{input_per_1m: Decimal.t(), output_per_1m: Decimal.t()}} | :error
  def lookup(model) when is_binary(model) do
    case Map.fetch(@table, model) do
      {:ok, prices} ->
        {:ok, prices}

      :error ->
        prefix_lookup(model)
    end
  end

  def lookup(_), do: :error

  @doc "Returns the static pricing map (for testing/inspection)."
  def table, do: @table

  defp prefix_lookup(model) do
    Enum.find_value(@table, :error, fn {prefix, prices} ->
      if String.starts_with?(model, prefix), do: {:ok, prices}, else: nil
    end)
  end
end
