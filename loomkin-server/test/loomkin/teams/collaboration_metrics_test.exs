defmodule Loomkin.Teams.CollaborationMetricsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{CollaborationMetrics, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "collab-metrics-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "record_event/2 and get_metrics/1" do
    test "starts with zero counters", %{team_id: team_id} do
      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.message_flow_count == 0
      assert metrics.discovery_share_count == 0
      assert metrics.conflict_count == 0
    end

    test "increments message_flow and discovery_share for discovery_shared", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :discovery_shared)
      CollaborationMetrics.record_event(team_id, :discovery_shared)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.message_flow_count == 2
      assert metrics.discovery_share_count == 2
    end

    test "increments question counters", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :question_asked)
      CollaborationMetrics.record_event(team_id, :question_asked)
      CollaborationMetrics.record_event(team_id, :question_answered)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.question_asked_count == 2
      assert metrics.question_answered_count == 1
    end

    test "increments conflict_count for conflict_detected", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :conflict_detected)
      CollaborationMetrics.record_event(team_id, :conflict_detected)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.conflict_count == 2
    end

    test "increments rebalance_count for task_rebalanced", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :task_rebalanced)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.rebalance_count == 1
      assert metrics.message_flow_count == 1
    end

    test "increments task counters", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :task_completed)
      CollaborationMetrics.record_event(team_id, :task_completed)
      CollaborationMetrics.record_event(team_id, :task_failed)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.task_completed_count == 2
      assert metrics.task_failed_count == 1
    end

    test "increments consensus_count", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :consensus_reached)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.consensus_count == 1
    end
  end

  describe "question resolution time" do
    test "computes avg resolution time from question ask/answer pairs", %{team_id: team_id} do
      CollaborationMetrics.record_event(team_id, :question_asked)
      # Small delay to get a measurable time
      Process.sleep(10)
      CollaborationMetrics.record_event(team_id, :question_answered)

      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.avg_question_resolution_ms > 0
    end

    test "returns 0 when no questions asked", %{team_id: team_id} do
      metrics = CollaborationMetrics.get_metrics(team_id)
      assert metrics.avg_question_resolution_ms == 0
    end
  end

  describe "collaboration_score/1" do
    test "returns a score between 0 and 100", %{team_id: team_id} do
      score = CollaborationMetrics.collaboration_score(team_id)
      assert score >= 0 and score <= 100
    end

    test "starts with a baseline score for new teams", %{team_id: team_id} do
      score = CollaborationMetrics.collaboration_score(team_id)
      # New team with no activity should have baseline + resolution + completion defaults
      assert score >= 20
    end

    test "score increases with positive activity", %{team_id: team_id} do
      before = CollaborationMetrics.collaboration_score(team_id)

      for _ <- 1..5 do
        CollaborationMetrics.record_event(team_id, :discovery_shared)
        CollaborationMetrics.record_event(team_id, :task_completed)
      end

      after_score = CollaborationMetrics.collaboration_score(team_id)
      assert after_score > before
    end

    test "score decreases with conflicts", %{team_id: team_id} do
      # Add some positive activity first
      for _ <- 1..5 do
        CollaborationMetrics.record_event(team_id, :discovery_shared)
      end

      before = CollaborationMetrics.collaboration_score(team_id)

      for _ <- 1..4 do
        CollaborationMetrics.record_event(team_id, :conflict_detected)
      end

      after_score = CollaborationMetrics.collaboration_score(team_id)
      assert after_score < before
    end

    test "score never exceeds 100", %{team_id: team_id} do
      for _ <- 1..50 do
        CollaborationMetrics.record_event(team_id, :discovery_shared)
        CollaborationMetrics.record_event(team_id, :task_completed)
        CollaborationMetrics.record_event(team_id, :consensus_reached)
      end

      score = CollaborationMetrics.collaboration_score(team_id)
      assert score <= 100
    end
  end
end
