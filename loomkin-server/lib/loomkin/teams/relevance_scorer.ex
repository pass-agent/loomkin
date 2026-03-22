defmodule Loomkin.Teams.RelevanceScorer do
  @moduledoc """
  Fast heuristic scoring for context relevance between a discovery and an agent.

  Returns a score from 0.0 to 1.0 based on:
  - Keyword overlap between discovery content and agent's current task
  - File path overlap (same files mentioned)
  - Role alignment (coding discoveries are more relevant to coders, etc.)

  No LLM calls — must be fast enough for inline filtering.
  """

  @default_threshold 0.3

  @doc """
  Score relevance of a discovery to an agent's context.

  Returns a float between 0.0 and 1.0.

  ## Parameters

    * `discovery` - map with `:content`, `:type`, `:from` keys
    * `agent_context` - map with optional `:task`, `:role`, `:name` keys

  """
  @spec score(map(), map()) :: float()
  def score(discovery, agent_context) do
    # Don't score discoveries from self
    if to_string(discovery[:from]) == to_string(agent_context[:name]) do
      0.0
    else
      keyword_score = keyword_overlap(discovery, agent_context)
      file_score = file_path_overlap(discovery, agent_context)
      role_score = role_alignment(discovery, agent_context)

      # Weighted combination: keywords most important, then files, then role
      raw = keyword_score * 0.5 + file_score * 0.3 + role_score * 0.2
      Float.round(min(raw, 1.0), 2)
    end
  end

  @doc """
  Filter a list of agents, returning only those with relevance above the threshold.

  Returns a list of `{agent_info, score}` tuples sorted by score descending.
  """
  @spec filter_relevant(map(), [map()], float()) :: [{map(), float()}]
  def filter_relevant(discovery, agents, threshold \\ @default_threshold) do
    agents
    |> Enum.map(fn agent -> {agent, score(discovery, agent)} end)
    |> Enum.filter(fn {_agent, s} -> s >= threshold end)
    |> Enum.sort_by(fn {_agent, s} -> s end, :desc)
  end

  @doc "Default relevance threshold."
  @spec default_threshold() :: float()
  def default_threshold, do: @default_threshold

  # -- Private scoring functions --

  defp keyword_overlap(discovery, agent_context) do
    discovery_words = extract_words(discovery[:content])
    task_words = extract_task_words(agent_context)

    if MapSet.size(discovery_words) == 0 or MapSet.size(task_words) == 0 do
      0.0
    else
      overlap = MapSet.intersection(discovery_words, task_words) |> MapSet.size()
      smaller = min(MapSet.size(discovery_words), MapSet.size(task_words))
      overlap / smaller
    end
  end

  defp file_path_overlap(discovery, agent_context) do
    discovery_paths = extract_file_paths(to_string(discovery[:content] || ""))
    task_paths = extract_file_paths(task_text(agent_context))

    if MapSet.size(discovery_paths) == 0 or MapSet.size(task_paths) == 0 do
      0.0
    else
      overlap = MapSet.intersection(discovery_paths, task_paths) |> MapSet.size()
      # Any shared file path is a strong signal
      min(overlap / MapSet.size(task_paths), 1.0)
    end
  end

  defp role_alignment(discovery, agent_context) do
    discovery_type = to_string(discovery[:type] || "")
    agent_role = agent_context[:role]

    cond do
      # Code-related discoveries are most relevant to coders
      code_related?(discovery_type) and agent_role in [:coder, :reviewer, :tester] -> 0.8
      # Research/insight discoveries are most relevant to researchers and leads
      research_related?(discovery_type) and agent_role in [:researcher, :lead] -> 0.8
      # Blockers are relevant to everyone
      discovery_type == "blocker" -> 0.7
      # Default: moderate relevance
      agent_role != nil -> 0.3
      true -> 0.1
    end
  end

  # -- Helpers --

  @stop_words MapSet.new(~w[
    the a an is are was were be been being have has had do does did
    will would shall should may might can could of to in for on with
    at by from as into through during before after above below between
    out off over under and but or nor not no so yet both each every
    all any few more most other some such this that these those it its
    i we you he she they me us him her them my our your his their
  ])

  defp extract_words(nil), do: MapSet.new()

  defp extract_words(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&MapSet.member?(@stop_words, &1))
    |> MapSet.new()
  end

  defp extract_words(_), do: MapSet.new()

  defp extract_task_words(agent_context) do
    task_text(agent_context) |> extract_words()
  end

  defp task_text(agent_context) do
    task = agent_context[:task] || %{}

    [
      task[:description],
      task[:title],
      to_string(task[:id] || "")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @file_path_regex ~r{(?:[\w./]+\.(?:ex|exs|js|ts|py|rb|go|rs|java|md|json|yaml|yml|toml|html|css|eex|heex))\b}

  defp extract_file_paths(text) when is_binary(text) do
    Regex.scan(@file_path_regex, text)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp extract_file_paths(_), do: MapSet.new()

  defp code_related?(type) do
    type in ~w[code implementation fix bug refactor edit file_change]
  end

  defp research_related?(type) do
    type in ~w[discovery insight finding analysis research observation]
  end
end
