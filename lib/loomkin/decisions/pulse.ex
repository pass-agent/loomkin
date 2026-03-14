defmodule Loomkin.Decisions.Pulse do
  @moduledoc "Generates pulse reports for the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode
  alias Loomkin.Decisions.Graph

  @default_confidence_threshold 50
  @default_stale_days 7

  def generate(opts \\ []) do
    confidence_threshold =
      Keyword.get(
        opts,
        :confidence_threshold,
        config_decisions(:pulse_confidence_threshold, @default_confidence_threshold)
      )

    stale_days =
      Keyword.get(
        opts,
        :stale_days,
        config_decisions(:pulse_stale_days, @default_stale_days)
      )

    active_goals = Graph.active_goals()
    recent_decisions = Graph.recent_decisions()
    coverage_gaps = find_coverage_gaps(active_goals)
    low_confidence = find_low_confidence(confidence_threshold)
    stale_nodes = find_stale_nodes(stale_days)
    health_score = compute_health(Keyword.put(opts, :confidence_threshold, confidence_threshold))

    %{
      active_goals: active_goals,
      recent_decisions: recent_decisions,
      coverage_gaps: coverage_gaps,
      low_confidence: low_confidence,
      stale_nodes: stale_nodes,
      health_score: health_score,
      summary:
        build_summary(active_goals, recent_decisions, coverage_gaps, low_confidence, stale_nodes)
    }
  end

  @doc "Computes a 0-100 health score for the decision graph."
  def compute_health(opts \\ []) do
    team_id = Keyword.get(opts, :team_id)

    confidence_threshold =
      Keyword.get(
        opts,
        :confidence_threshold,
        config_decisions(:pulse_confidence_threshold, @default_confidence_threshold)
      )

    active_nodes = list_active_nodes(team_id)
    all_edges = list_all_edges(team_id, active_nodes)

    gap_count = count_coverage_gaps(active_nodes, all_edges)
    orphan_count = count_orphans(active_nodes, all_edges)
    low_confidence_count = count_low_confidence(active_nodes, confidence_threshold)

    100 - min(gap_count * 10, 50) - min(orphan_count * 5, 30) - min(low_confidence_count * 3, 20)
  end

  defp list_active_nodes(nil) do
    DecisionNode
    |> where([n], n.status == :active)
    |> Repo.all()
  end

  defp list_active_nodes(team_id) do
    DecisionNode
    |> where([n], n.status == :active)
    |> where([n], fragment("? ->> 'team_id' = ?", n.metadata, ^team_id))
    |> Repo.all()
  end

  defp list_all_edges(nil, _nodes), do: Repo.all(DecisionEdge)

  defp list_all_edges(_team_id, active_nodes) do
    node_ids = Enum.map(active_nodes, & &1.id)

    DecisionEdge
    |> where([e], e.from_node_id in ^node_ids or e.to_node_id in ^node_ids)
    |> Repo.all()
  end

  defp count_coverage_gaps(active_nodes, all_edges) do
    gap_types = [:goal, :decision]

    active_nodes
    |> Enum.filter(&(&1.node_type in gap_types))
    |> Enum.count(fn node ->
      outgoing_target_ids =
        all_edges
        |> Enum.filter(&(&1.from_node_id == node.id))
        |> Enum.map(& &1.to_node_id)
        |> MapSet.new()

      connected_types =
        active_nodes
        |> Enum.filter(&MapSet.member?(outgoing_target_ids, &1.id))
        |> Enum.map(& &1.node_type)

      not Enum.any?(connected_types, &(&1 in [:action, :outcome]))
    end)
  end

  defp count_orphans(active_nodes, all_edges) do
    edge_node_ids =
      all_edges
      |> Enum.flat_map(&[&1.from_node_id, &1.to_node_id])
      |> MapSet.new()

    active_nodes
    |> Enum.reject(&(&1.node_type == :goal))
    |> Enum.count(&(not MapSet.member?(edge_node_ids, &1.id)))
  end

  defp count_low_confidence(active_nodes, threshold) do
    Enum.count(active_nodes, fn node ->
      node.confidence != nil and node.confidence < threshold
    end)
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

  defp config_decisions(key, default) do
    Loomkin.Config.get(:decisions, key) || default
  end
end
