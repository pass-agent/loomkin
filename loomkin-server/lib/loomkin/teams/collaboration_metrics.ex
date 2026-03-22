defmodule Loomkin.Teams.CollaborationMetrics do
  @moduledoc "Track per-team collaboration health metrics in ETS."

  alias Loomkin.Teams.TableRegistry

  @metric_keys [
    :message_flow_count,
    :discovery_share_count,
    :question_asked_count,
    :question_answered_count,
    :task_completed_count,
    :task_failed_count,
    :conflict_count,
    :rebalance_count,
    :consensus_count
  ]

  @doc "Record a collaboration event, incrementing the appropriate counters."
  def record_event(team_id, event_type) do
    keys = metric_keys_for(event_type)

    Enum.each(keys, fn key ->
      increment(team_id, key)
    end)

    # Track question timestamps for resolution time
    case event_type do
      :question_asked ->
        push_timestamp(team_id, :question_asked_at, System.monotonic_time(:millisecond))

      :question_answered ->
        record_resolution_time(team_id)

      _ ->
        :ok
    end
  end

  @doc "Get all metrics for a team as a map."
  def get_metrics(team_id) do
    base =
      Map.new(@metric_keys, fn key ->
        {key, get_counter(team_id, key)}
      end)

    resolution_time = avg_resolution_time(team_id)
    score = compute_collaboration_score(base, resolution_time)

    base
    |> Map.put(:avg_question_resolution_ms, resolution_time)
    |> Map.put(:collaboration_score, score)
  end

  @doc "Get the composite collaboration score (0-100) for a team."
  def collaboration_score(team_id) do
    metrics = get_metrics(team_id)
    metrics.collaboration_score
  end

  # -- Private --

  defp metric_keys_for(:discovery_shared), do: [:message_flow_count, :discovery_share_count]
  defp metric_keys_for(:question_asked), do: [:message_flow_count, :question_asked_count]
  defp metric_keys_for(:question_answered), do: [:message_flow_count, :question_answered_count]
  defp metric_keys_for(:task_completed), do: [:task_completed_count]
  defp metric_keys_for(:task_failed), do: [:task_failed_count]
  defp metric_keys_for(:conflict_detected), do: [:conflict_count]
  defp metric_keys_for(:task_rebalanced), do: [:message_flow_count, :rebalance_count]
  defp metric_keys_for(:consensus_reached), do: [:message_flow_count, :consensus_count]
  defp metric_keys_for(:consensus_success), do: [:message_flow_count, :consensus_count]
  defp metric_keys_for(:consensus_deadlock), do: [:message_flow_count, :conflict_count]
  defp metric_keys_for(:consensus_escalation), do: [:message_flow_count, :conflict_count]
  defp metric_keys_for(:knowledge_propagated), do: [:message_flow_count, :discovery_share_count]
  defp metric_keys_for(_), do: [:message_flow_count]

  defp increment(team_id, key) do
    table = TableRegistry.get_table!(team_id)
    :ets.update_counter(table, {:metric, key}, {2, 1}, {{:metric, key}, 0})
  rescue
    ArgumentError -> :ok
  end

  defp get_counter(team_id, key) do
    table = TableRegistry.get_table!(team_id)

    case :ets.lookup(table, {:metric, key}) do
      [{{:metric, ^key}, val}] -> val
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp push_timestamp(team_id, key, ts) do
    table = TableRegistry.get_table!(team_id)
    existing = get_timestamps(team_id, key)
    # Keep last 100 timestamps to bound memory
    trimmed = Enum.take(existing, -99)
    :ets.insert(table, {{:metric_ts, key}, trimmed ++ [ts]})
  rescue
    ArgumentError -> :ok
  end

  defp get_timestamps(team_id, key) do
    table = TableRegistry.get_table!(team_id)

    case :ets.lookup(table, {:metric_ts, key}) do
      [{{:metric_ts, ^key}, list}] -> list
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp record_resolution_time(team_id) do
    now = System.monotonic_time(:millisecond)
    asked_timestamps = get_timestamps(team_id, :question_asked_at)

    case asked_timestamps do
      [] ->
        :ok

      [oldest | rest] ->
        # Pop the oldest unanswered question timestamp
        table = TableRegistry.get_table!(team_id)
        :ets.insert(table, {{:metric_ts, :question_asked_at}, rest})
        elapsed = now - oldest
        push_timestamp(team_id, :resolution_times, elapsed)
    end
  rescue
    ArgumentError -> :ok
  end

  defp avg_resolution_time(team_id) do
    times = get_timestamps(team_id, :resolution_times)

    case times do
      [] -> 0
      list -> div(Enum.sum(list), length(list))
    end
  end

  defp compute_collaboration_score(metrics, avg_resolution_ms) do
    # Composite score from 0-100
    # Positive signals: discoveries, answered questions, completions, consensus
    # Negative signals: conflicts, failures, slow resolution

    total_activity =
      metrics.discovery_share_count +
        metrics.question_answered_count +
        metrics.task_completed_count +
        metrics.consensus_count

    # Activity score: 0-40 points (caps at 20 events)
    activity_score = min(total_activity * 2, 40)

    # Resolution score: 0-20 points (fast = good, >60s = 0)
    resolution_score =
      cond do
        avg_resolution_ms == 0 and metrics.question_asked_count == 0 -> 20
        avg_resolution_ms == 0 -> 10
        avg_resolution_ms < 5_000 -> 20
        avg_resolution_ms < 30_000 -> 15
        avg_resolution_ms < 60_000 -> 10
        true -> 0
      end

    # Completion ratio: 0-20 points
    total_tasks = metrics.task_completed_count + metrics.task_failed_count

    completion_score =
      if total_tasks > 0 do
        round(metrics.task_completed_count / total_tasks * 20)
      else
        10
      end

    # Conflict penalty: -5 per conflict, max -20
    conflict_penalty = min(metrics.conflict_count * 5, 20)

    # Base of 20 to avoid teams starting at 0
    base = 20

    score = base + activity_score + resolution_score + completion_score - conflict_penalty
    max(0, min(100, score))
  end
end
