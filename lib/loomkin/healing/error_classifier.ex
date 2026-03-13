defmodule Loomkin.Healing.ErrorClassifier do
  @moduledoc """
  Classifies tool errors and agent failures into healing categories.

  Determines whether an error should trigger the self-healing flow,
  be retried by the agent itself, or be escalated immediately.
  """

  @type error_category ::
          :compile_error
          | :lint_error
          | :command_failure
          | :test_failure
          | :tool_error
          | :resource_error
          | :unknown

  @type severity :: :low | :medium | :high | :critical

  @type classification :: %{
          category: error_category(),
          severity: severity(),
          healable: boolean(),
          error_context: map(),
          suggested_approach: String.t()
        }

  @doc """
  Classify an error from tool output or agent loop failure.
  Returns a classification with category, severity, and healability.

  `context` may include:
    * `:tool_name` - the tool that produced the error
    * `:retry_count` - how many times this error has been retried
    * `:file_path` - the file involved in the error
  """
  @spec classify(String.t(), map()) :: classification()
  def classify(error_text, context \\ %{})

  def classify(error_text, context) when is_binary(error_text) do
    category = detect_category(error_text)
    severity = assess_severity(category, error_text)

    %{
      category: category,
      severity: severity,
      healable: healable?(category, context),
      error_context: build_error_context(category, error_text, context),
      suggested_approach: suggest_approach(category, error_text)
    }
  end

  def classify(_error_text, _context) do
    %{
      category: :unknown,
      severity: :low,
      healable: false,
      error_context: %{},
      suggested_approach: "Unable to classify non-string error"
    }
  end

  @doc """
  Determine if this error should trigger healing or if the agent
  should handle it inline.

  `agent_state` may include:
    * `:failure_count` - consecutive failures for this agent
    * `:role` - the agent's current role
    * `:healing_budget_remaining` - remaining healing budget
    * `:healing_enabled` - whether healing is enabled for this role
  """
  @spec should_heal?(classification(), map()) :: boolean()
  def should_heal?(classification, agent_state \\ %{})

  def should_heal?(%{healable: false}, _agent_state), do: false

  def should_heal?(%{category: category, severity: severity}, agent_state) do
    healing_enabled?(agent_state) and
      category_allowed?(category, agent_state) and
      above_failure_threshold?(category, agent_state) and
      above_severity_threshold?(severity) and
      has_healing_budget?(agent_state)
  end

  # -- Category detection ------------------------------------------------------

  defp detect_category(error_text) do
    cond do
      compile_error?(error_text) -> :compile_error
      lint_error?(error_text) -> :lint_error
      test_failure?(error_text) -> :test_failure
      resource_error?(error_text) -> :resource_error
      command_failure?(error_text) -> :command_failure
      tool_error?(error_text) -> :tool_error
      true -> :unknown
    end
  end

  defp compile_error?(text) do
    String.contains?(text, "** (CompileError)") or
      String.contains?(text, "undefined function") or
      String.contains?(text, "undefined variable") or
      text =~ ~r/module .+ is not available/ or
      String.contains?(text, "(UndefinedFunctionError)") or
      String.contains?(text, "(SyntaxError)") or
      String.contains?(text, "cannot compile") or
      String.contains?(text, "== Compilation error")
  end

  defp lint_error?(text) do
    String.contains?(text, "mix format") or
      (String.contains?(text, "** (Mix)") and String.contains?(text, "format")) or
      (String.contains?(text, "[W] ") and String.contains?(text, "credo")) or
      text =~ ~r/\bcredo\b/i or
      String.contains?(text, "Files were not formatted")
  end

  defp test_failure?(text) do
    text =~ ~r/\d+ tests?, \d+ failures?/ or
      String.contains?(text, "** (ExUnit.") or
      String.contains?(text, "Assertion with") or
      (String.contains?(text, "assert") and String.contains?(text, "FAILED")) or
      text =~ ~r/test .+ FAILED/
  end

  defp resource_error?(text) do
    text =~ ~r/rate.?limit/i or
      (text =~ ~r/\btimeout\b/i and text =~ ~r/exceeded|expired/i) or
      String.contains?(text, "budget exceeded") or
      (String.contains?(text, "429") and text =~ ~r/too many requests/i) or
      String.contains?(text, "quota exceeded")
  end

  defp command_failure?(text) do
    text =~ ~r/exit code:?\s*[1-9]\d*/i or
      text =~ ~r/exited with \d+/ or
      String.contains?(text, "non-zero exit") or
      String.contains?(text, "command failed") or
      (String.contains?(text, "** (ErlangError)") and String.contains?(text, "exit"))
  end

  defp tool_error?(text) do
    String.contains?(text, "File not found") or
      String.contains?(text, "Permission denied") or
      String.contains?(text, "Error: Tool") or
      String.contains?(text, "Error: No such file") or
      String.contains?(text, "Error: Cannot write") or
      String.starts_with?(text, "Error:")
  end

  # -- Healability rules -------------------------------------------------------

  defp healable?(:compile_error, _context), do: true
  defp healable?(:lint_error, _context), do: false
  defp healable?(:test_failure, _context), do: true

  defp healable?(:command_failure, %{retry_count: n}) when is_integer(n) and n >= 2, do: false
  defp healable?(:command_failure, _context), do: true

  defp healable?(:tool_error, %{tool_name: name})
       when name in ~w(file_edit file_write shell file_read),
       do: true

  defp healable?(:tool_error, _context), do: false
  defp healable?(:resource_error, _context), do: false
  defp healable?(:unknown, _context), do: false

  # -- Severity assessment -----------------------------------------------------

  defp assess_severity(:compile_error, text) do
    if text =~ ~r/SyntaxError/ or String.contains?(text, "cannot compile") do
      :high
    else
      :medium
    end
  end

  defp assess_severity(:lint_error, _text), do: :low

  defp assess_severity(:test_failure, text) do
    case Regex.run(~r/(\d+) failures?/, text) do
      [_, count] ->
        if String.to_integer(count) > 5, do: :high, else: :medium

      _ ->
        :medium
    end
  end

  defp assess_severity(:command_failure, text) do
    if text =~ ~r/permission denied/i or text =~ ~r/segmentation fault/i do
      :critical
    else
      :medium
    end
  end

  defp assess_severity(:tool_error, _text), do: :medium
  defp assess_severity(:resource_error, _text), do: :high
  defp assess_severity(:unknown, _text), do: :low

  # -- should_heal? helpers ----------------------------------------------------

  @failure_thresholds %{
    compile_error: 1,
    lint_error: 1,
    test_failure: 1,
    command_failure: 2,
    tool_error: 2
  }

  defp healing_enabled?(%{healing_enabled: false}), do: false
  defp healing_enabled?(_agent_state), do: true

  defp category_allowed?(category, %{healing_categories: categories})
       when is_list(categories) and categories != [] do
    category in categories
  end

  defp category_allowed?(_category, _agent_state), do: true

  defp above_failure_threshold?(category, agent_state) do
    # Use policy threshold if provided, otherwise fall back to default per-category thresholds
    threshold =
      case Map.get(agent_state, :failure_threshold) do
        t when is_integer(t) and t > 0 -> t
        _ -> Map.get(@failure_thresholds, category, 1)
      end

    failure_count = Map.get(agent_state, :failure_count, 0)
    failure_count >= threshold
  end

  defp above_severity_threshold?(:low), do: false
  defp above_severity_threshold?(_severity), do: true

  defp has_healing_budget?(%{healing_budget_remaining: budget})
       when is_number(budget) and budget <= 0,
       do: false

  defp has_healing_budget?(_agent_state), do: true

  # -- Error context building --------------------------------------------------

  defp build_error_context(:compile_error, text, context) do
    file = extract_file_path(text) || context[:file_path]
    line = extract_line_number(text)

    Map.merge(context, %{file_path: file, line: line})
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp build_error_context(:test_failure, text, context) do
    failure_count = extract_failure_count(text)
    file = extract_file_path(text) || context[:file_path]

    Map.merge(context, %{test_failure_count: failure_count, file_path: file})
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp build_error_context(_category, _text, context), do: context

  defp extract_file_path(text) do
    case Regex.run(~r{(?:^|\s)([\w./\-]+\.(?:ex|exs)):(\d+)}, text) do
      [_, path, _line] -> path
      _ -> nil
    end
  end

  defp extract_line_number(text) do
    case Regex.run(~r{\.(?:ex|exs):(\d+)}, text) do
      [_, line] -> String.to_integer(line)
      _ -> nil
    end
  end

  defp extract_failure_count(text) do
    case Regex.run(~r/(\d+) failures?/, text) do
      [_, count] -> String.to_integer(count)
      _ -> nil
    end
  end

  # -- Suggested approach ------------------------------------------------------

  defp suggest_approach(:compile_error, text) do
    cond do
      String.contains?(text, "undefined function") ->
        "Check for missing imports, aliases, or misspelled function names"

      text =~ ~r/module .+ is not available/ ->
        "Verify the module exists and is properly aliased or imported"

      String.contains?(text, "SyntaxError") ->
        "Review file for syntax issues: missing do/end, unclosed brackets, or stray characters"

      true ->
        "Read the file referenced in the error, check LSP diagnostics, and identify the compilation issue"
    end
  end

  defp suggest_approach(:lint_error, _text) do
    "Run mix format to auto-fix formatting issues, then check credo warnings"
  end

  defp suggest_approach(:command_failure, text) do
    cond do
      text =~ ~r/permission denied/i ->
        "Check file permissions and ensure the command has appropriate access"

      text =~ ~r/not found|command not found/i ->
        "Verify the command exists and is available in the current environment"

      true ->
        "Analyze the command's stderr output, check exit code, and determine the root cause"
    end
  end

  defp suggest_approach(:test_failure, _text) do
    "Run the failing test in isolation, read the test file and implementation, identify the assertion mismatch"
  end

  defp suggest_approach(:tool_error, text) do
    cond do
      String.contains?(text, "File not found") or String.contains?(text, "No such file") ->
        "Verify the file path exists and is correctly spelled"

      String.contains?(text, "Permission denied") ->
        "Check file permissions for the target path"

      true ->
        "Examine the tool error details and retry with corrected parameters"
    end
  end

  defp suggest_approach(:resource_error, _text) do
    "Resource error detected — wait and retry, or escalate to the user"
  end

  defp suggest_approach(:unknown, _text) do
    "Unrecognized error — escalate to the lead agent or user for triage"
  end
end
