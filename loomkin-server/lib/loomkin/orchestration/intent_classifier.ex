defmodule Loomkin.Orchestration.IntentClassifier do
  @moduledoc """
  Combines `Loomkin.Orchestration.IntentRules` with a small-LLM fallback for
  `:ambiguous` messages.

  Telemetry: emits `[:loomkin, :orchestration, :intent, :classified]` with
  `%{intent, via, duration_ms}` on every call.

  Configuration keys (under `:loomkin, Loomkin.Orchestration`):

    * `:fast_model` — overrides the default model used for the LLM fallback.
    * `:intent_llm_timeout_ms` — fallback timeout. Default 2_000.
  """

  alias Loomkin.Orchestration.{IntentRules, LLM}

  @system_prompt """
  You classify the user's message into ONE of these intents and respond with strict JSON only.

  Intents:
    - "fast_chat"     — pure conversation, no code change needed
    - "tool_use"      — a single deterministic tool call (run tests, show diff, etc.)
    - "complex_task"  — implementation or design work that benefits from a plan + review

  Output format (no prose outside the JSON):

    {"intent": "fast_chat" | "tool_use" | "complex_task",
     "confidence": "high" | "medium" | "low",
     "rationale": "<one short sentence>"}
  """

  @doc """
  Classify a message.

  Returns `{intent, via, reason}` where `via` is `:rule_<n>` when a rule decided,
  `:llm` when the LLM fallback decided, or `:llm_fallback_failsafe` when the LLM
  was unavailable.
  """
  @spec classify(String.t() | nil, keyword()) ::
          {IntentRules.t(), atom(), String.t()}
  def classify(message, opts \\ []) do
    start = System.monotonic_time(:microsecond)

    {intent, via, reason} =
      case IntentRules.classify(message, opts) do
        {:ambiguous, rule_reason} ->
          {llm_intent, llm_reason} = llm_fallback(message, opts)
          {llm_intent, classify_via(llm_intent, rule_reason), llm_reason}

        {intent, reason} ->
          {intent, {:rule, IntentRules.which_rule(message)}, reason}
      end

    duration_ms = div(System.monotonic_time(:microsecond) - start, 1000)

    :telemetry.execute(
      [:loomkin, :orchestration, :intent, :classified],
      %{duration_ms: duration_ms},
      %{intent: intent, via: via}
    )

    {intent, via, reason}
  end

  defp classify_via(_intent, _reason), do: :llm

  defp llm_fallback(message, opts) do
    timeout =
      Application.get_env(:loomkin, Loomkin.Orchestration, [])
      |> Keyword.get(:intent_llm_timeout_ms, 2_000)

    model =
      opts[:model] ||
        Application.get_env(:loomkin, Loomkin.Orchestration, [])
        |> Keyword.get(:fast_model)

    llm_opts =
      [reviewer: :intent_classifier, timeout: timeout]
      |> maybe_put(:model, model)

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: message || ""}
    ]

    case safe_complete(messages, llm_opts) do
      {:ok, text} ->
        decode_intent(text)

      {:error, reason} ->
        {:complex_task, "llm fallback failed: #{inspect(reason)} — fail-safe to complex"}
    end
  end

  defp safe_complete(messages, opts) do
    LLM.complete(messages, opts)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, reason -> {:error, reason}
  end

  defp decode_intent(text) do
    text
    |> String.trim()
    |> strip_code_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{"intent" => "fast_chat"} = m} ->
        {:fast_chat, "llm:#{m["confidence"] || "?"}: #{m["rationale"] || ""}"}

      {:ok, %{"intent" => "tool_use"} = m} ->
        {:tool_use, "llm:#{m["confidence"] || "?"}: #{m["rationale"] || ""}"}

      {:ok, %{"intent" => "complex_task"} = m} ->
        {:complex_task, "llm:#{m["confidence"] || "?"}: #{m["rationale"] || ""}"}

      {:ok, other} ->
        {:complex_task, "llm returned unknown shape #{inspect(other)} — fail-safe to complex"}

      {:error, _} ->
        {:complex_task, "llm output not JSON — fail-safe to complex"}
    end
  end

  defp strip_code_fences(text) do
    cond do
      String.starts_with?(text, "```json") ->
        text
        |> String.replace_prefix("```json", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      String.starts_with?(text, "```") ->
        text
        |> String.replace_prefix("```", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        text
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
