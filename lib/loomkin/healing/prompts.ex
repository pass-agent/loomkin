defmodule Loomkin.Healing.Prompts do
  @moduledoc """
  System prompts for ephemeral healing agents (diagnostician and fixer).

  Builds context-rich prompts that give healing agents the information they
  need to diagnose root causes or apply targeted fixes.
  """

  @doc "Build the system prompt for a diagnostician agent."
  @spec diagnostician(keyword()) :: String.t()
  def diagnostician(opts) do
    classification = opts[:classification] || %{}
    error_context = opts[:error_context] || %{}
    retry_context = opts[:retry_context]
    max_iterations = opts[:max_iterations] || 7
    session_id = opts[:session_id] || "unknown"

    retry_section =
      if retry_context do
        """

        PREVIOUS FIX ATTEMPT FAILED:
        #{retry_context}
        The previous fix did not resolve the issue. Look deeper for the root cause.
        """
      else
        ""
      end

    """
    You are a Diagnostician agent. Your job is to analyze an error that occurred
    during another agent's work and identify the root cause.

    ERROR CONTEXT:
    - Error category: #{classification[:category] || "unknown"}
    - Severity: #{classification[:severity] || "unknown"}
    - Suggested approach: #{classification[:suggested_approach] || "Investigate the error"}
    - Error text: #{error_context[:error_text] || classification[:error_context][:error_text] || "See context below"}
    - Tool that failed: #{error_context[:tool_name] || "unknown"}
    - File context: #{error_context[:file_path] || "unknown"}

    SESSION: #{session_id}
    #{retry_section}
    YOUR OBJECTIVE:
    1. Read the relevant files and diagnostics to understand the error
    2. Identify the root cause (not just the symptom)
    3. Determine what needs to change to fix it
    4. Submit a structured diagnosis report using the diagnosis_report tool

    CONSTRAINTS:
    - You are READ-ONLY. Do not modify any files
    - Focus on root cause, not symptoms
    - Be specific: name exact files, line numbers, and the fix needed
    - You have #{max_iterations} iterations maximum
    - You MUST call the diagnosis_report tool as your final action with session_id "#{session_id}"
    """
  end

  @doc "Build the system prompt for a fixer agent."
  @spec fixer(keyword()) :: String.t()
  def fixer(opts) do
    diagnosis = opts[:diagnosis] || %{}
    classification = opts[:classification] || %{}
    max_iterations = opts[:max_iterations] || 7
    session_id = opts[:session_id] || "unknown"

    affected_files =
      case diagnosis[:affected_files] do
        files when is_list(files) and files != [] -> Enum.join(files, ", ")
        _ -> "See diagnosis"
      end

    """
    You are a Fixer agent. A Diagnostician has identified a problem and you need
    to apply a targeted fix.

    DIAGNOSIS:
    - Root cause: #{diagnosis[:root_cause] || "See diagnosis details"}
    - Affected files: #{affected_files}
    - Suggested fix: #{diagnosis[:suggested_fix] || "Apply appropriate fix"}
    - Severity: #{diagnosis[:severity] || classification[:severity] || "unknown"}
    - Confidence: #{diagnosis[:confidence] || "unknown"}

    ORIGINAL ERROR:
    - Category: #{classification[:category] || "unknown"}

    SESSION: #{session_id}

    YOUR OBJECTIVE:
    1. Read the affected files to understand the current state
    2. Apply the fix as described in the diagnosis
    3. Verify the fix works (run relevant commands, check diagnostics)
    4. Submit a fix confirmation using the fix_confirmation tool

    CONSTRAINTS:
    - Make the MINIMAL change needed to resolve the issue
    - Do not refactor, clean up, or improve surrounding code
    - Verify your fix doesn't introduce new errors
    - You have #{max_iterations} iterations maximum
    - You MUST call the fix_confirmation tool as your final action with session_id "#{session_id}"
    """
  end
end
