defmodule Loomkin.Orchestration.IntentRules do
  @moduledoc """
  Pure-function rule classifier for user-message intent.

  No IO, no LLM, no state. Returns one of:

    * `{:fast_chat, reason}`     — greetings, short Q&A, no code
    * `{:tool_use, reason}`      — action verb without file scope
    * `{:complex_task, reason}`  — has DoD/spec keywords, diffs, or action+file
    * `{:ambiguous, reason}`     — caller should fall back to LLM classification

  See `docs/orchestration/INTENT_CLASSIFIER.md` for the rule list with examples.
  """

  @typedoc "Intent classification result."
  @type t :: :fast_chat | :tool_use | :complex_task | :ambiguous
  @type result :: {t(), reason :: String.t()}

  @greetings ~w(hi hello hey yo sup morning evening thanks ty ok okay cool nice
                sure yes no nope yeah nah)

  @greeting_phrases [
    "thank you",
    "sounds good",
    "got it",
    "understood",
    "good morning",
    "good evening",
    "all good",
    "no worries"
  ]

  @action_verbs ~w(implement add build create refactor fix repair debug test migrate
                   port wire extract inline rename delete remove replace simplify
                   optimize parallelize document audit review lint format
                   run show list open close check explain summarize generate
                   apply revert stage commit push pull merge rebase)

  @spec_keywords ~w(dod acceptance criterion criteria requirement requirements
                    spec specification scope deliverable deliverables)

  @path_regex ~r{(?:^|\s)([a-zA-Z0-9_./-]+\.(?:ex|exs|heex|ts|tsx|js|jsx|md|json|yml|yaml|sql|sh))}
  @action_verb_regex ~r/\b(#{Enum.join(@action_verbs, "|")})\b/i

  @doc """
  Classify a message using rules only. Caller decides what to do with `:ambiguous`.

  `opts` may carry `:current_context` (a map) for future context-aware rules.
  Currently context is unused but the signature is set so callers don't churn.
  """
  @spec classify(String.t() | nil, keyword()) :: result()
  def classify(message, _opts \\ [])

  def classify(nil, _opts), do: {:fast_chat, "nil message"}

  def classify(message, _opts) when is_binary(message) do
    trimmed = String.trim(message)
    downcase = String.downcase(trimmed)

    cond do
      trimmed == "" ->
        {:fast_chat, "empty message"}

      String.length(trimmed) <= 3 ->
        {:fast_chat, "length<=3"}

      greeting?(downcase) ->
        {:fast_chat, "greeting"}

      has_diff_fence?(trimmed) ->
        {:complex_task, "diff/patch in code fence"}

      multi_paragraph_spec?(trimmed, downcase) ->
        {:complex_task, "spec-style message with DoD keywords"}

      action_verb?(downcase) and has_file_path?(trimmed) ->
        {:complex_task, "action verb + file path"}

      question_no_code_short?(trimmed) ->
        {:fast_chat, "short question, no code, no file path"}

      action_verb?(downcase) and short?(trimmed) ->
        {:tool_use, "action verb, no file scope, short"}

      true ->
        {:ambiguous, "no rule matched"}
    end
  end

  @doc "Returns the rule index (1-based) that produced the verdict, or 0 for :ambiguous."
  @spec which_rule(String.t() | nil) :: non_neg_integer()
  def which_rule(message) do
    case classify(message) do
      {_, "empty message"} -> 1
      {_, "nil message"} -> 1
      {_, "length<=3"} -> 2
      {_, "greeting"} -> 3
      {_, "diff/patch in code fence"} -> 5
      {_, "spec-style message with DoD keywords"} -> 8
      {_, "action verb + file path"} -> 6
      {_, "short question, no code, no file path"} -> 4
      {_, "action verb, no file scope, short"} -> 7
      {_, _} -> 0
    end
  end

  ## Predicates

  defp greeting?(downcase) do
    cond do
      downcase in @greetings ->
        true

      Enum.any?(@greeting_phrases, &(&1 == downcase)) ->
        true

      # Short message that starts with a greeting word + punctuation
      starts_with_greeting_word?(downcase) and String.length(downcase) <= 40 ->
        true

      true ->
        false
    end
  end

  defp starts_with_greeting_word?(downcase) do
    Enum.any?(@greetings, fn g ->
      downcase == g or String.starts_with?(downcase, g <> " ") or
        String.starts_with?(downcase, g <> ",") or
        String.starts_with?(downcase, g <> "!") or
        String.starts_with?(downcase, g <> ".")
    end)
  end

  defp has_diff_fence?(text) do
    String.contains?(text, "```") and
      (String.contains?(text, "@@") or String.contains?(text, "diff --git") or
         String.contains?(text, "+++ ") or String.contains?(text, "--- "))
  end

  defp multi_paragraph_spec?(text, downcase) do
    String.contains?(text, "\n\n") and
      Enum.any?(@spec_keywords, &String.contains?(downcase, &1))
  end

  defp action_verb?(downcase), do: Regex.match?(@action_verb_regex, downcase)

  defp has_file_path?(text), do: Regex.match?(@path_regex, text)

  defp question_no_code_short?(text) do
    String.contains?(text, "?") and
      not String.contains?(text, "```") and
      not has_file_path?(text) and
      String.length(text) <= 280
  end

  defp short?(text), do: String.length(text) <= 200
end
