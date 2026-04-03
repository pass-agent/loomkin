defmodule Loomkin.Decisions.Pulse do
  @moduledoc "Generates pulse reports for the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode
  alias Loomkin.Decisions.Graph

  @default_confidence_threshold 50
  @default_stale_days 7
  @cache_table :pulse_health_cache
  @default_cache_ttl_ms 5 * 60 * 1000

  def ensure_cache_table do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc "Invalidates the cached health score for a team (or global when nil)."
  def invalidate_cache(team_id \\ nil) do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete(@cache_table, team_id)
    end

    :ok
  end

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

  @doc "Computes a 0-100 health score for the decision graph. Results are cached per team_id."
  def compute_health(opts \\ []) do
    team_id = Keyword.get(opts, :team_id)
    ttl = Keyword.get(opts, :cache_ttl_ms, config_cache_ttl())

    ensure_cache_table()

    case lookup_cache(team_id, ttl) do
      {:ok, score} ->
        score

      :miss ->
        score = compute_health_uncached(team_id, opts)
        :ets.insert(@cache_table, {team_id, score, System.monotonic_time(:millisecond)})
        score
    end
  end

  defp lookup_cache(team_id, ttl) do
    case :ets.lookup(@cache_table, team_id) do
      [{^team_id, score, cached_at}] ->
        now = System.monotonic_time(:millisecond)

        if now - cached_at < ttl do
          {:ok, score}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp compute_health_uncached(team_id, opts) do
    confidence_threshold =
      Keyword.get(
        opts,
        :confidence_threshold,
        config_decisions(:pulse_confidence_threshold, @default_confidence_threshold)
      )

    gap_count = count_coverage_gaps_db(team_id)
    orphan_count = count_orphans_db(team_id)
    low_confidence_count = count_low_confidence_db(team_id, confidence_threshold)

    100 - min(gap_count * 10, 50) - min(orphan_count * 5, 30) - min(low_confidence_count * 3, 20)
  end

  defp count_low_confidence_db(nil, threshold) do
    DecisionNode
    |> where([n], n.status == :active)
    |> where([n], not is_nil(n.confidence))
    |> where([n], n.confidence < ^threshold)
    |> Repo.aggregate(:count)
  end

  defp count_low_confidence_db(team_id, threshold) do
    DecisionNode
    |> where([n], n.status == :active)
    |> where([n], fragment("? ->> 'team_id' = ?", n.metadata, ^team_id))
    |> where([n], not is_nil(n.confidence))
    |> where([n], n.confidence < ^threshold)
    |> Repo.aggregate(:count)
  end

  defp count_orphans_db(team_id) do
    active_q = active_nodes_query(team_id)

    # Non-goal active nodes that have no edges (neither from nor to)
    from(n in subquery(active_q),
      as: :node,
      where: n.node_type != :goal,
      where:
        not exists(
          from(e in DecisionEdge,
            where: e.from_node_id == parent_as(:node).id or e.to_node_id == parent_as(:node).id
          )
        )
    )
    |> Repo.aggregate(:count)
  end

  defp count_coverage_gaps_db(team_id) do
    active_q = active_nodes_query(team_id)

    # Goal/decision nodes that have no outgoing edge to an :action or :outcome node
    from(n in subquery(active_q),
      as: :node,
      where: n.node_type in [:goal, :decision],
      where:
        not exists(
          from(e in DecisionEdge,
            join: target in DecisionNode,
            on: target.id == e.to_node_id,
            where: e.from_node_id == parent_as(:node).id,
            where: target.node_type in [:action, :outcome]
          )
        )
    )
    |> Repo.aggregate(:count)
  end

  defp active_nodes_query(nil) do
    from(n in DecisionNode,
      where: n.status == :active,
      select: %{id: n.id, node_type: n.node_type}
    )
  end

  defp active_nodes_query(team_id) do
    from(n in DecisionNode,
      where: n.status == :active,
      where: fragment("? ->> 'team_id' = ?", n.metadata, ^team_id),
      select: %{id: n.id, node_type: n.node_type}
    )
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

  defp config_cache_ttl do
    Loomkin.Config.get(:decisions, :pulse_cache_ttl_ms) || @default_cache_ttl_ms
  end
end
