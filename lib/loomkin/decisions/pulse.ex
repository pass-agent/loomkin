defmodule Loomkin.Decisions.Pulse do
  @moduledoc "Generates pulse reports for the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.{DecisionNode, DecisionEdge}
  alias Loomkin.Decisions.Graph

  @default_confidence_threshold 50
  @default_stale_days 7

  def generate(opts \\ []) do
    confidence_threshold = Keyword.get(opts, :confidence_threshold, @default_confidence_threshold)
    stale_days = Keyword.get(opts, :stale_days, @default_stale_days)

    active_goals = Graph.active_goals()
    recent_decisions = Graph.recent_decisions()
    coverage_gaps = find_coverage_gaps(active_goals)
    low_confidence = find_low_confidence(confidence_threshold)
    stale_nodes = find_stale_nodes(stale_days)

    %{
      active_goals: active_goals,
      recent_decisions: recent_decisions,
      coverage_gaps: coverage_gaps,
      low_confidence: low_confidence,
      stale_nodes: stale_nodes,
      summary: build_summary(active_goals, recent_decisions, coverage_gaps, low_confidence, stale_nodes)
    }
  end

  defp find_coverage_gaps(goals) do
    Enum.filter(goals, fn goal ->
      connected_types =
        DecisionEdge
        |> where([e], e.from_node_id == ^goal.id)
        |> join(:inner, [e], n in DecisionNode, on: e.to_node_id == n.id)
        |> select([_e, n], n.node_type)
        |> Repo.all()

      not Enum.any?(connected_types, &(&1 in [:action, :outcome]))
    end)
  end

  defp find_low_confidence(threshold) do
    DecisionNode
    |> where([n], n.status == :active)
    |> where([n], not is_nil(n.confidence))
    |> where([n], n.confidence < ^threshold)
    |> Repo.all()
  end

  defp find_stale_nodes(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    DecisionNode
    |> where([n], n.status == :active)
    |> where([n], n.updated_at < ^cutoff)
    |> Repo.all()
  end

  defp build_summary(goals, decisions, gaps, low_conf, stale) do
    parts = [
      "#{length(goals)} active goal(s)",
      "#{length(decisions)} recent decision(s)",
      "#{length(gaps)} coverage gap(s)",
      "#{length(low_conf)} low-confidence node(s)",
      "#{length(stale)} stale node(s)"
    ]

    "Pulse: " <> Enum.join(parts, ", ") <> "."
  end
end
