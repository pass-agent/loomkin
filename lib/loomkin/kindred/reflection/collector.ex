defmodule Loomkin.Kindred.Reflection.Collector do
  @moduledoc """
  Gathers retrospection data from existing systems for the reflection agent.

  Sources:
  - AgentMetric records (success rates, costs, duration by model/task_type)
  - Failure memory keepers (topics matching "failures:*")
  - Decision graph nodes with confidence/status
  - Task journal entries
  - Capabilities ETS (per-agent success rates by task type)
  """

  require Logger

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.AgentMetric
  alias Loomkin.Workspace.TaskJournalEntry

  @spec collect(String.t(), keyword()) :: map()
  def collect(workspace_id, opts \\ []) do
    lookback = Keyword.get(opts, :lookback_hours, 24)
    since = DateTime.utc_now() |> DateTime.add(-lookback * 3600, :second)

    %{
      metrics_summary: collect_metrics(workspace_id, since),
      failure_patterns: collect_failure_patterns(workspace_id),
      decision_outcomes: collect_decision_outcomes(workspace_id),
      task_journal: collect_task_journal(workspace_id, since),
      capability_scores: collect_capability_scores(workspace_id)
    }
  end

  defp collect_metrics(workspace_id, since) do
    # Get workspace's team_id to scope metrics
    case get_workspace_team_id(workspace_id) do
      nil ->
        %{total: 0, by_model: %{}, by_task_type: %{}}

      team_id ->
        metrics =
          AgentMetric
          |> where([m], m.team_id == ^team_id and m.inserted_at >= ^since)
          |> Repo.all()

        by_model =
          metrics
          |> Enum.group_by(& &1.model)
          |> Enum.map(fn {model, ms} ->
            {model,
             %{
               count: length(ms),
               avg_duration_ms: avg(ms, :duration_ms),
               total_cost: sum(ms, :cost_usd),
               success_rate: success_rate(ms)
             }}
          end)
          |> Map.new()

        by_task_type =
          metrics
          |> Enum.group_by(& &1.task_type)
          |> Enum.map(fn {type, ms} ->
            {type,
             %{
               count: length(ms),
               success_rate: success_rate(ms)
             }}
          end)
          |> Map.new()

        %{total: length(metrics), by_model: by_model, by_task_type: by_task_type}
    end
  rescue
    e ->
      Logger.warning("[Reflection.Collector] collect_metrics failed: #{inspect(e)}")
      %{total: 0, by_model: %{}, by_task_type: %{}}
  end

  defp collect_failure_patterns(workspace_id) do
    case get_workspace_team_id(workspace_id) do
      nil ->
        []

      team_id ->
        try do
          Loomkin.Teams.ContextRetrieval.search(team_id, "failures:")
          |> Enum.take(20)
          |> Enum.map(fn keeper ->
            %{
              topic: Map.get(keeper, :topic, "unknown"),
              content: String.slice(Map.get(keeper, :content, "") || "", 0, 500),
              staleness: Map.get(keeper, :staleness)
            }
          end)
        rescue
          e ->
            Logger.warning(
              "[Reflection.Collector] collect_failure_patterns failed: #{inspect(e)}"
            )

            []
        end
    end
  end

  defp collect_decision_outcomes(workspace_id) do
    case get_workspace_team_id(workspace_id) do
      nil ->
        []

      team_id ->
        try do
          Loomkin.Decisions.Graph.list_nodes(team_id: team_id)
          |> Enum.take(50)
          |> Enum.map(fn node ->
            %{
              id: node.id,
              title: node.title,
              node_type: node.node_type,
              status: node.status,
              confidence: node.confidence
            }
          end)
        rescue
          e ->
            Logger.warning(
              "[Reflection.Collector] collect_decision_outcomes failed: #{inspect(e)}"
            )

            []
        end
    end
  end

  defp collect_task_journal(workspace_id, since) do
    TaskJournalEntry
    |> where([t], t.workspace_id == ^workspace_id and t.inserted_at >= ^since)
    |> order_by([t], desc: t.inserted_at)
    |> limit(50)
    |> Repo.all()
    |> Enum.map(fn entry ->
      %{
        task_id: entry.task_id,
        status: entry.status,
        result_summary: String.slice(entry.result_summary || "", 0, 300),
        inserted_at: entry.inserted_at
      }
    end)
  rescue
    e ->
      Logger.warning("[Reflection.Collector] collect_task_journal failed: #{inspect(e)}")
      []
  end

  defp collect_capability_scores(workspace_id) do
    case get_workspace_team_id(workspace_id) do
      nil ->
        %{}

      _team_id ->
        # Capabilities are stored in ETS per agent; we'd need to enumerate
        # all agents to collect scores. Return empty for now — the other
        # data sources (metrics, failures, decisions) are more actionable.
        %{}
    end
  end

  defp get_workspace_team_id(workspace_id) do
    case Loomkin.Workspace
         |> where([w], w.id == ^workspace_id)
         |> select([w], w.team_id)
         |> Repo.one() do
      nil -> nil
      team_id -> team_id
    end
  rescue
    e ->
      Logger.warning("[Reflection.Collector] get_workspace_team_id failed: #{inspect(e)}")
      nil
  end

  defp avg([], _field), do: 0

  defp avg(metrics, field) do
    values = Enum.map(metrics, &Map.get(&1, field, 0)) |> Enum.reject(&is_nil/1)

    if values == [] do
      0
    else
      Enum.sum(values) / length(values)
    end
  end

  defp sum(metrics, field) do
    metrics
    |> Enum.map(&Map.get(&1, field, 0))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp success_rate([]), do: 0.0

  defp success_rate(metrics) do
    successes = Enum.count(metrics, & &1.success)
    successes / length(metrics)
  end
end
