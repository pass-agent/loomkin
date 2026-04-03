defmodule Loomkin.Teams.Learning do
  @moduledoc """
  Cross-session learning from agent performance metrics.

  Records task outcomes (success/failure, cost, tokens, duration) and queries
  historical data to recommend models and team compositions for future tasks.

  ## Integration Point

  Call `record_task_result/1` when a task completes. The natural hook is in
  `Loomkin.Teams.Tasks.complete_task/2` — after persisting cost via CostTracker,
  call:

      Learning.record_task_result(%{
        team_id: task.team_id,
        agent_name: task.owner,
        role: agent_role,
        model: model_used,
        task_type: classify_task(task),
        success: true,
        cost_usd: usage.cost,
        tokens_used: usage.input_tokens + usage.output_tokens,
        duration_ms: elapsed,
        project_path: project_path
      })

  Similarly, `Loomkin.Teams.Tasks.fail_task/2` should record with `success: false`.
  """

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.AgentMetric

  @doc """
  Record a task result as an agent metric.

  ## Required params
    * `:team_id` - team identifier
    * `:agent_name` - agent who performed the task
    * `:model` - model string used (e.g. "anthropic:claude-sonnet-4-6")
    * `:task_type` - category of task (e.g. "code_edit", "review", "test")
    * `:success` - boolean

  ## Optional params
    * `:role` - agent role
    * `:cost_usd` - cost in USD (float)
    * `:tokens_used` - total tokens consumed (integer)
    * `:duration_ms` - wall-clock duration in milliseconds
    * `:project_path` - project path for context
    * `:scope_tier` - scope tier string (e.g. "surgical", "scoped", "broad", "transformative")
    * `:files_touched` - number of files touched by the task
  """
  @spec record_task_result(map()) :: {:ok, AgentMetric.t()} | {:error, Ecto.Changeset.t()}
  def record_task_result(params) when is_map(params) do
    %AgentMetric{}
    |> AgentMetric.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Success rate for a model on a given task type.

  Returns a float between 0.0 and 1.0, or `nil` if no data exists.
  """
  @spec success_rate(String.t(), String.t()) :: float() | nil
  def success_rate(model, task_type) do
    query =
      from m in AgentMetric,
        where: m.model == ^model and m.task_type == ^task_type,
        select: %{
          total: count(m.id),
          successes: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success))
        }

    case Repo.one(query) do
      %{total: 0} -> nil
      %{total: total, successes: successes} -> successes / total
    end
  end

  @doc """
  Average cost (USD) for a given task type across all models.

  Returns `nil` if no data exists.
  """
  @spec avg_cost(String.t()) :: float() | nil
  def avg_cost(task_type) do
    query =
      from m in AgentMetric,
        where: m.task_type == ^task_type and not is_nil(m.cost_usd),
        select: avg(m.cost_usd)

    Repo.one(query)
  end

  @doc """
  Recommend the best model for a task type based on success rate and cost efficiency.

  Ranks models by a composite score: `success_rate * (1 / (1 + avg_cost))`.
  This favors models that succeed often and cheaply.

  Returns `{model, score}` or `nil` if no data exists.
  """
  @spec recommend_model(String.t()) :: {String.t(), float()} | nil
  def recommend_model(task_type) do
    query =
      from m in AgentMetric,
        where: m.task_type == ^task_type,
        group_by: m.model,
        having: count(m.id) >= 1,
        select: %{
          model: m.model,
          total: count(m.id),
          successes: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success)),
          avg_cost: avg(m.cost_usd)
        }

    Repo.all(query)
    |> Enum.map(fn %{model: model, total: total, successes: successes, avg_cost: avg_cost} ->
      rate = successes / total
      cost = avg_cost || 0.0
      score = rate * (1 / (1 + cost))
      {model, score}
    end)
    |> Enum.max_by(fn {_model, score} -> score end, fn -> nil end)
  end

  @doc """
  Recommend a team composition for a project type based on historical performance.

  Analyzes which roles and models performed best for a given task type pattern,
  returning a list of `%{role: role, model: model, success_rate: rate}` sorted
  by success rate descending.
  """
  @spec recommend_team(String.t()) :: [map()]
  def recommend_team(project_type) do
    query =
      from m in AgentMetric,
        where: m.task_type == ^project_type and not is_nil(m.role),
        group_by: [m.role, m.model],
        having: count(m.id) >= 1,
        select: %{
          role: m.role,
          model: m.model,
          total: count(m.id),
          successes: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success))
        }

    Repo.all(query)
    |> Enum.map(fn %{role: role, model: model, total: total, successes: successes} ->
      %{role: role, model: model, success_rate: successes / total}
    end)
    |> Enum.sort_by(& &1.success_rate, :desc)
  end

  @doc """
  Top-performing agents/models ranked by success rate.

  ## Options
    * `:limit` - max results (default 10)
    * `:task_type` - filter by task type
    * `:min_tasks` - minimum number of tasks to qualify (default 1)
    * `:group_by` - `:model` or `:agent` (default `:model`)
  """
  @spec top_performers(keyword()) :: [map()]
  def top_performers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_tasks = Keyword.get(opts, :min_tasks, 1)
    task_type = Keyword.get(opts, :task_type)
    group = Keyword.get(opts, :group_by, :model)

    base =
      from m in AgentMetric,
        select: %{
          total: count(m.id),
          successes: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success)),
          avg_cost: avg(m.cost_usd),
          avg_duration_ms: avg(m.duration_ms)
        }

    base =
      case group do
        :agent ->
          base
          |> group_by([m], [m.agent_name, m.model])
          |> select_merge([m], %{name: m.agent_name, model: m.model})

        _ ->
          base
          |> group_by([m], m.model)
          |> select_merge([m], %{name: m.model})
      end

    base =
      if task_type do
        where(base, [m], m.task_type == ^task_type)
      else
        base
      end

    base
    |> having([m], count(m.id) >= ^min_tasks)
    |> Repo.all()
    |> Enum.map(fn row ->
      rate = row.successes / row.total
      Map.put(row, :success_rate, rate)
    end)
    |> Enum.sort_by(& &1.success_rate, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Average cost (USD) for tasks of a given scope tier.

  Takes a scope tier as an atom or string. Returns `nil` if no data exists.
  """
  @spec avg_cost_by_scope(atom() | String.t()) :: float() | nil
  def avg_cost_by_scope(scope_tier) do
    tier = to_string(scope_tier)

    query =
      from m in AgentMetric,
        where: m.scope_tier == ^tier and not is_nil(m.cost_usd),
        select: avg(m.cost_usd)

    Repo.one(query)
  end

  @doc """
  Recommend a scope tier based on historical velocity data.

  Takes a map with `:task_description` (string) and `:file_matches` (integer).
  Infers a tier from file_matches, then checks historical data.

  Returns:
    * `{:learned, tier, avg_cost}` if 5+ historical records exist for the tier
    * `{:default, tier}` if insufficient data
  """
  @spec recommend_tier(map()) :: {:learned, String.t(), float()} | {:default, String.t()}
  def recommend_tier(%{file_matches: file_matches} = _params) do
    tier = infer_tier(file_matches)

    query =
      from m in AgentMetric,
        where: m.scope_tier == ^tier,
        select: %{count: count(m.id), avg_cost: avg(m.cost_usd)}

    case Repo.one(query) do
      %{count: count, avg_cost: avg_cost} when count >= 5 and not is_nil(avg_cost) ->
        {:learned, tier, avg_cost}

      _ ->
        {:default, tier}
    end
  end

  defp infer_tier(file_matches) when is_integer(file_matches) do
    cond do
      file_matches <= 3 -> "quick"
      file_matches <= 15 -> "session"
      true -> "campaign"
    end
  end
end
