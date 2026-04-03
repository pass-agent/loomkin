defmodule Loomkin.Kindred.Reflection.Agent do
  @moduledoc """
  Ephemeral reflection agent that analyzes collected data and produces
  structured recommendations for kindred evolution.

  Follows the Healing.EphemeralAgent pattern — short-lived, budget-capped,
  focused on a single task.
  """

  require Logger

  alias Loomkin.Kindred.Reflection.Prompts
  alias Loomkin.Telemetry, as: LoomkinTelemetry

  @default_budget_usd 0.25
  @default_model "anthropic:claude-sonnet-4-6"

  @doc """
  Run a reflection analysis on the collected data.

  Returns structured output with report and recommendations.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(collected_data, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    budget = Keyword.get(opts, :budget_usd, @default_budget_usd)

    system_prompt = Prompts.system_prompt()
    context = Prompts.build_context(collected_data)

    user_message = """
    Analyze the following workspace performance data and provide recommendations
    for improving the kindred (agent bundle) configuration.

    #{context}

    Respond with:
    1. A markdown analysis section
    2. A JSON code block with structured recommendations
    """

    case call_llm(model, system_prompt, user_message, budget) do
      {:ok, response} ->
        {:ok, parse_response(response)}

      {:error, reason} ->
        Logger.warning("[Reflection] Agent failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp call_llm(model, system_prompt, user_message, _budget) do
    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_message}
    ]

    meta = %{model: model, caller: __MODULE__, function: :call_llm}

    case LoomkinTelemetry.span_llm_request(meta, fn ->
           Loomkin.LLM.generate_text(model, messages, [])
         end) do
      {:ok, %{text: text}} ->
        {:ok, text}

      {:ok, text} when is_binary(text) ->
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Reflection] LLM call failed: #{inspect(e)}")
      {:error, :llm_unavailable}
  end

  defp parse_response(response) when is_binary(response) do
    # Extract JSON block from response
    recommendations =
      case Regex.run(~r/```json\s*\n([\s\S]*?)\n\s*```/, response) do
        [_, json_str] ->
          case Jason.decode(json_str) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        nil ->
          %{}
      end

    confidence = Map.get(recommendations, "confidence", 0.5)

    %{
      report: response,
      recommendations: Map.get(recommendations, "recommendations", []),
      confidence: confidence
    }
  end

  defp parse_response(_), do: %{report: "", recommendations: [], confidence: 0.0}
end
