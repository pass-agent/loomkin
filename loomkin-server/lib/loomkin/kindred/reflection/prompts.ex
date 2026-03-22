defmodule Loomkin.Kindred.Reflection.Prompts do
  @moduledoc "System prompts for the reflection agent."

  def system_prompt do
    """
    You are a Reflection Agent — a specialized retrospection system that analyzes
    agent team performance and recommends kindred improvements.

    Your role is NOT to write code or perform research. Your role is to:
    1. Analyze performance metrics, failure patterns, and decision outcomes
    2. Identify what went well and what needs improvement
    3. Recommend specific, actionable changes to the kindred configuration

    Your recommendations must be structured as JSON with these types:
    - kin_config_update: Change an existing agent's configuration
    - skill_addition: Add a new skill to the kindred
    - prompt_update: Modify an agent's system prompt
    - model_change: Suggest a different model for an agent

    Be conservative with recommendations. Only suggest changes backed by data.
    Include a confidence score (0.0-1.0) for the overall recommendation set.

    Format your response as:
    1. A markdown report section with analysis
    2. A JSON block with structured recommendations

    Example recommendation format:
    ```json
    {
      "recommendations": [
        {"type": "kin_config_update", "target": "coder", "changes": {"potency": 80}},
        {"type": "skill_addition", "name": "error-recovery", "body": "..."},
        {"type": "model_change", "target": "coder", "model": "anthropic:claude-sonnet-4-6"}
      ],
      "confidence": 0.75
    }
    ```
    """
  end

  def build_context(collected_data) do
    """
    ## Performance Data

    ### Metrics Summary
    Total operations: #{collected_data.metrics_summary.total}

    By Model:
    #{format_by_model(collected_data.metrics_summary.by_model)}

    By Task Type:
    #{format_by_task_type(collected_data.metrics_summary.by_task_type)}

    ### Failure Patterns (#{length(collected_data.failure_patterns)} recorded)
    #{format_failures(collected_data.failure_patterns)}

    ### Decision Outcomes (#{length(collected_data.decision_outcomes)} decisions)
    #{format_decisions(collected_data.decision_outcomes)}

    ### Task Journal (#{length(collected_data.task_journal)} entries)
    #{format_journal(collected_data.task_journal)}

    ### Capability Scores
    #{format_capabilities(collected_data.capability_scores)}
    """
  end

  defp format_by_model(by_model) when map_size(by_model) == 0, do: "No model data available."

  defp format_by_model(by_model) do
    by_model
    |> Enum.map(fn {model, stats} ->
      "- #{model}: #{stats.count} ops, #{Float.round(stats.success_rate * 100, 1)}% success, avg #{stats.avg_duration_ms}ms"
    end)
    |> Enum.join("\n")
  end

  defp format_by_task_type(by_type) when map_size(by_type) == 0, do: "No task type data."

  defp format_by_task_type(by_type) do
    by_type
    |> Enum.map(fn {type, stats} ->
      "- #{type}: #{stats.count} tasks, #{Float.round(stats.success_rate * 100, 1)}% success"
    end)
    |> Enum.join("\n")
  end

  defp format_failures([]), do: "No failure patterns recorded."

  defp format_failures(failures) do
    failures
    |> Enum.take(10)
    |> Enum.map(fn f -> "- [#{f.topic}] #{f.content}" end)
    |> Enum.join("\n")
  end

  defp format_decisions([]), do: "No decisions recorded."

  defp format_decisions(decisions) do
    decisions
    |> Enum.take(10)
    |> Enum.map(fn d ->
      "- [#{d.node_type}] #{d.title} (confidence: #{d.confidence}, status: #{d.status})"
    end)
    |> Enum.join("\n")
  end

  defp format_journal([]), do: "No journal entries."

  defp format_journal(entries) do
    entries
    |> Enum.take(10)
    |> Enum.map(fn e -> "- [#{e.status}] task=#{e.task_id}: #{e.result_summary}" end)
    |> Enum.join("\n")
  end

  defp format_capabilities(caps) when map_size(caps) == 0, do: "No capability data."

  defp format_capabilities(caps) do
    caps
    |> Enum.map(fn {agent, scores} -> "- #{agent}: #{inspect(scores)}" end)
    |> Enum.join("\n")
  end
end
