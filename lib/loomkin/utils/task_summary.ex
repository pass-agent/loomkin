defmodule Loomkin.Utils.TaskSummary do
  @moduledoc """
  Utilities for formatting and summarizing task completion data.

  Works with the completion attributes from `Loomkin.Tools.PeerCompleteTask`
  and `Loomkin.Schemas.TeamTask` records to produce human-readable summaries,
  extract metrics, and assess completion quality.
  """

  @type completion_attrs :: %{
          result: String.t(),
          actions_taken: [String.t()],
          discoveries: [String.t()],
          files_changed: [String.t()],
          decisions_made: [String.t()],
          open_questions: [String.t()]
        }

  @type metrics :: %{
          artifact_count: non_neg_integer(),
          action_count: non_neg_integer(),
          discovery_count: non_neg_integer(),
          file_count: non_neg_integer(),
          decision_count: non_neg_integer(),
          open_question_count: non_neg_integer(),
          result_length: non_neg_integer(),
          quality_score: float()
        }

  @doc """
  Formats a completion attrs map into a human-readable summary string.

  ## Examples

      iex> attrs = %{
      ...>   result: "Implemented the new feature",
      ...>   actions_taken: ["Added module X", "Updated config"],
      ...>   discoveries: ["Found legacy pattern in auth"],
      ...>   files_changed: ["lib/app/feature.ex", "config/config.exs"],
      ...>   decisions_made: ["Used GenServer over Agent"],
      ...>   open_questions: []
      ...> }
      iex> Loomkin.Utils.TaskSummary.format_completion(attrs)
  """
  @spec format_completion(completion_attrs()) :: String.t()
  def format_completion(attrs) when is_map(attrs) do
    metrics = extract_metrics(attrs)

    sections =
      [
        format_result_section(attrs),
        format_list_section("Actions Taken", Map.get(attrs, :actions_taken, [])),
        format_list_section("Discoveries", Map.get(attrs, :discoveries, [])),
        format_list_section("Files Changed", Map.get(attrs, :files_changed, [])),
        format_list_section("Decisions Made", Map.get(attrs, :decisions_made, [])),
        format_list_section("Open Questions", Map.get(attrs, :open_questions, [])),
        format_metrics_footer(metrics)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  @doc """
  Extracts key metrics from task completion attributes.

  Returns a map with counts for each field and a quality score (0.0 to 1.0)
  based on how thoroughly the completion was filled out.
  """
  @spec extract_metrics(completion_attrs()) :: metrics()
  def extract_metrics(attrs) when is_map(attrs) do
    actions = Map.get(attrs, :actions_taken, [])
    discoveries = Map.get(attrs, :discoveries, [])
    files = Map.get(attrs, :files_changed, [])
    decisions = Map.get(attrs, :decisions_made, [])
    questions = Map.get(attrs, :open_questions, [])
    result = Map.get(attrs, :result, "")

    action_count = safe_length(actions)
    discovery_count = safe_length(discoveries)
    file_count = safe_length(files)
    decision_count = safe_length(decisions)
    question_count = safe_length(questions)
    result_length = if is_binary(result), do: String.length(String.trim(result)), else: 0

    %{
      artifact_count: action_count + discovery_count + file_count,
      action_count: action_count,
      discovery_count: discovery_count,
      file_count: file_count,
      decision_count: decision_count,
      open_question_count: question_count,
      result_length: result_length,
      quality_score:
        compute_quality_score(result_length, action_count, discovery_count, file_count)
    }
  end

  @doc """
  Returns a quality assessment label based on the completion data.

  - `:excellent` — rich result with multiple artifact types
  - `:good` — meaningful result with at least one artifact type
  - `:minimal` — has result and one artifact but sparse
  - `:poor` — missing key fields
  - `:empty` — no meaningful content
  """
  @spec quality_label(completion_attrs()) :: :excellent | :good | :minimal | :poor | :empty
  def quality_label(attrs) when is_map(attrs) do
    %{quality_score: score} = extract_metrics(attrs)

    cond do
      score >= 0.8 -> :excellent
      score >= 0.5 -> :good
      score >= 0.3 -> :minimal
      score > 0.0 -> :poor
      true -> :empty
    end
  end

  @doc """
  Groups changed files by directory, useful for understanding the scope of changes.

  ## Examples

      iex> files = ["lib/app/auth/token.ex", "lib/app/auth/session.ex", "test/app/auth/token_test.exs"]
      iex> Loomkin.Utils.TaskSummary.group_files_by_directory(files)
      %{
        "lib/app/auth" => ["token.ex", "session.ex"],
        "test/app/auth" => ["token_test.exs"]
      }
  """
  @spec group_files_by_directory([String.t()]) :: %{String.t() => [String.t()]}
  def group_files_by_directory(files) when is_list(files) do
    files
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.group_by(&Path.dirname/1, &Path.basename/1)
  end

  @doc """
  Produces a one-line summary suitable for task lists or logs.
  """
  @spec one_line_summary(completion_attrs()) :: String.t()
  def one_line_summary(attrs) when is_map(attrs) do
    metrics = extract_metrics(attrs)
    label = quality_label(attrs)
    result = Map.get(attrs, :result, "") |> truncate(80)

    "[#{label}] #{result} (#{metrics.file_count} files, #{metrics.action_count} actions, #{metrics.discovery_count} discoveries)"
  end

  @doc """
  Merges completion data from multiple tasks into a combined summary.
  Useful when aggregating sub-task results for a parent task.
  """
  @spec merge_completions([completion_attrs()]) :: completion_attrs()
  def merge_completions(completions) when is_list(completions) do
    %{
      result: completions |> Enum.map_join("\n---\n", &Map.get(&1, :result, "")),
      actions_taken: completions |> Enum.flat_map(&Map.get(&1, :actions_taken, [])),
      discoveries: completions |> Enum.flat_map(&Map.get(&1, :discoveries, [])),
      files_changed:
        completions |> Enum.flat_map(&Map.get(&1, :files_changed, [])) |> Enum.uniq(),
      decisions_made: completions |> Enum.flat_map(&Map.get(&1, :decisions_made, [])),
      open_questions: completions |> Enum.flat_map(&Map.get(&1, :open_questions, []))
    }
  end

  # -- Private helpers --

  defp format_result_section(attrs) do
    result = Map.get(attrs, :result, "")

    if is_binary(result) and String.trim(result) != "" do
      "## Result\n#{String.trim(result)}"
    end
  end

  defp format_list_section(_heading, list) when list in [nil, []], do: nil

  defp format_list_section(heading, list) when is_list(list) do
    items = Enum.map_join(list, "\n", &"  - #{&1}")
    "### #{heading}\n#{items}"
  end

  defp format_metrics_footer(metrics) do
    "---\n" <>
      "Artifacts: #{metrics.artifact_count} " <>
      "(#{metrics.action_count} actions, #{metrics.discovery_count} discoveries, #{metrics.file_count} files) " <>
      "| Quality: #{Float.round(metrics.quality_score * 100, 0)}%"
  end

  defp compute_quality_score(result_length, action_count, discovery_count, file_count) do
    # Score components (each 0.0 to 1.0, then weighted)
    result_score = min(result_length / 100.0, 1.0)
    action_score = min(action_count / 3.0, 1.0)
    discovery_score = min(discovery_count / 2.0, 1.0)
    file_score = min(file_count / 2.0, 1.0)

    # Weighted average: result matters most, then files, then actions, then discoveries
    (result_score * 0.3 + file_score * 0.3 + action_score * 0.25 + discovery_score * 0.15)
    |> Float.round(2)
  end

  defp truncate(str, max_len) when is_binary(str) do
    str = String.trim(str)

    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 3) <> "..."
    else
      str
    end
  end

  defp truncate(_, _), do: ""

  defp safe_length(list) when is_list(list), do: length(list)
  defp safe_length(_), do: 0
end
