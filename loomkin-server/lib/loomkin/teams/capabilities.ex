defmodule Loomkin.Teams.Capabilities do
  @moduledoc "Per-team agent capability tracking via ETS. Records task completions and infers best agent for a task type."

  @task_types ~w(coding research review testing planning documentation debugging infrastructure)a

  @type_keywords %{
    coding: ~w(implement write code create add build fix refactor module function endpoint),
    research: ~w(research investigate explore analyze find search look discover examine study),
    review: ~w(review check audit inspect validate verify assess evaluate),
    testing: ~w(test spec assert coverage unit integration),
    planning: ~w(plan design decompose break architect outline structure organize),
    documentation: ~w(document readme doc comment explain describe),
    debugging: ~w(debug diagnose troubleshoot trace error crash bug issue),
    infrastructure: ~w(deploy config setup ci cd pipeline docker container infra)
  }

  # -- Recording --

  @doc "Record a task completion (success or failure) for an agent."
  def record_completion(team_id, agent_name, task_type, outcome)
      when outcome in [:success, :failure] do
    task_type = normalize_type(task_type)
    key = {:capability, agent_name, task_type}
    table = team_table(team_id)

    current =
      case :ets.lookup(table, key) do
        [{^key, stats}] -> stats
        [] -> %{successes: 0, failures: 0}
      end

    updated =
      case outcome do
        :success -> %{current | successes: current.successes + 1}
        :failure -> %{current | failures: current.failures + 1}
      end

    :ets.insert(table, {key, updated})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Get all capability stats for an agent."
  def get_capabilities(team_id, agent_name) do
    :ets.match_object(team_table(team_id), {{:capability, agent_name, :_}, :_})
    |> Enum.map(fn {{:capability, _name, task_type}, stats} ->
      Map.merge(stats, %{task_type: task_type, score: score(stats)})
    end)
    |> Enum.sort_by(& &1.score, :desc)
  rescue
    ArgumentError -> []
  end

  @doc "Return agents ranked by capability score for a given task type."
  def best_agent_for(team_id, task_type) do
    task_type = normalize_type(task_type)

    :ets.match_object(team_table(team_id), {{:capability, :_, task_type}, :_})
    |> Enum.map(fn {{:capability, agent_name, _type}, stats} ->
      %{agent: agent_name, score: score(stats), stats: stats}
    end)
    |> Enum.sort_by(& &1.score, :desc)
  rescue
    ArgumentError -> []
  end

  @doc "Infer a task type from a title/description string."
  @spec infer_task_type(String.t() | nil) :: atom()
  def infer_task_type(nil), do: :coding
  def infer_task_type(""), do: :coding

  def infer_task_type(text) when is_binary(text) do
    downcased = String.downcase(text)

    {best_type, best_count} =
      Enum.map(@type_keywords, fn {type, keywords} ->
        count = Enum.count(keywords, fn kw -> String.contains?(downcased, kw) end)
        {type, count}
      end)
      |> Enum.max_by(fn {_type, count} -> count end)

    if best_count > 0, do: best_type, else: :coding
  end

  @doc "List all known task types."
  def task_types, do: @task_types

  # -- Private --

  defp score(%{successes: s, failures: f}) do
    total = s + f
    if total == 0, do: 0.0, else: s / total * :math.log2(total + 1)
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :coding
  end

  defp team_table(team_id), do: Loomkin.Teams.TableRegistry.get_table!(team_id)
end
