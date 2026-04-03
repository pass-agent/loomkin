defmodule Loomkin.Decisions.PulseHealthTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.Pulse

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  describe "compute_health/1" do
    test "returns 100 for empty graph" do
      assert Pulse.compute_health() == 100
    end

    test "penalizes coverage gaps (goals with no action/outcome)" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Uncovered goal"}))

      health = Pulse.compute_health()
      # 1 gap => -10
      assert health == 90
    end

    test "penalizes coverage gaps for decisions too" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :decision, title: "Uncovered decision"}))

      health = Pulse.compute_health()
      # 1 gap (decision) + 1 orphan (non-goal with no edges) => -10 - 5 = 85
      assert health == 85
    end

    test "no gap penalty when goal has action child" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Covered goal"}))
      {:ok, action} = Graph.add_node(node_attrs(%{node_type: :action, title: "Action"}))
      {:ok, _} = Graph.add_edge(goal.id, action.id, :leads_to)

      health = Pulse.compute_health()
      assert health == 100
    end

    test "penalizes orphan nodes (non-goal active nodes with no edges)" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :action, title: "Orphan action"}))
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :observation, title: "Orphan obs"}))

      health = Pulse.compute_health()
      # 2 orphans => -10
      assert health == 90
    end

    test "goals are not counted as orphans" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Lone goal"}))

      health = Pulse.compute_health()
      # 1 gap (goal with no action/outcome) => -10, but no orphan penalty
      assert health == 90
    end

    test "penalizes low confidence nodes" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Goal", confidence: 30}))

      {:ok, action} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Act", confidence: 20}))

      {:ok, _} = Graph.add_edge(goal.id, action.id, :leads_to)

      health = Pulse.compute_health()
      # 0 gaps (goal has action), 0 orphans (both connected), 2 low conf => -6
      assert health == 94
    end

    test "caps gap penalty at 50" do
      for i <- 1..10 do
        Graph.add_node(node_attrs(%{node_type: :goal, title: "Gap #{i}"}))
      end

      health = Pulse.compute_health()
      # 10 gaps => min(100, 50) = -50
      assert health == 50
    end

    test "caps orphan penalty at 30" do
      for i <- 1..10 do
        Graph.add_node(node_attrs(%{node_type: :action, title: "Orphan #{i}"}))
      end

      health = Pulse.compute_health()
      # 0 gaps, 10 orphans => min(50, 30) = -30
      assert health == 70
    end

    test "caps low confidence penalty at 20" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Goal"}))

      for i <- 1..10 do
        {:ok, action} =
          Graph.add_node(node_attrs(%{node_type: :action, title: "Low #{i}", confidence: 10}))

        Graph.add_edge(goal.id, action.id, :leads_to)
      end

      health = Pulse.compute_health()
      # 0 gaps (goal has action children), 0 orphans, 10 low conf => min(30, 20) = -20
      assert health == 80
    end

    test "combined penalties" do
      # 1 uncovered goal (gap)
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, title: "Gap"}))
      # 1 orphan action with low confidence
      {:ok, _} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Orphan", confidence: 10}))

      health = Pulse.compute_health()
      # 1 gap (-10) + 1 orphan (-5) + 1 low conf (-3) = 82
      assert health == 82
    end

    test "scopes by team_id" do
      team_a = Ecto.UUID.generate()
      team_b = Ecto.UUID.generate()

      # Team A: uncovered goal
      {:ok, _} =
        Graph.add_node(
          node_attrs(%{node_type: :goal, title: "Team A goal", metadata: %{"team_id" => team_a}})
        )

      # Team B: covered goal
      {:ok, goal_b} =
        Graph.add_node(
          node_attrs(%{node_type: :goal, title: "Team B goal", metadata: %{"team_id" => team_b}})
        )

      {:ok, action_b} =
        Graph.add_node(
          node_attrs(%{
            node_type: :action,
            title: "Team B action",
            metadata: %{"team_id" => team_b}
          })
        )

      {:ok, _} = Graph.add_edge(goal_b.id, action_b.id, :leads_to)

      # Team A has a gap
      assert Pulse.compute_health(team_id: team_a) == 90
      # Team B is healthy
      assert Pulse.compute_health(team_id: team_b) == 100
    end

    test "health_score is included in generate/1" do
      report = Pulse.generate()
      assert Map.has_key?(report, :health_score)
      assert is_integer(report.health_score)
      assert report.health_score >= 0 and report.health_score <= 100
    end

    test "superseded nodes are not counted" do
      {:ok, _old} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Old", status: :superseded}))

      {:ok, _new} = Graph.add_node(node_attrs(%{node_type: :action, title: "New"}))

      health = Pulse.compute_health()
      # Only 1 orphan (the new active action), old is superseded and ignored
      assert health == 95
    end
  end
end
