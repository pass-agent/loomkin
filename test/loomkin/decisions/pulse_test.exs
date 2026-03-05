defmodule Loomkin.Decisions.PulseTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Graph, Pulse}

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  describe "generate/1" do
    test "returns a pulse report with all keys" do
      report = Pulse.generate()

      assert Map.has_key?(report, :active_goals)
      assert Map.has_key?(report, :recent_decisions)
      assert Map.has_key?(report, :coverage_gaps)
      assert Map.has_key?(report, :low_confidence)
      assert Map.has_key?(report, :stale_nodes)
      assert Map.has_key?(report, :summary)
    end

    test "summary is a human-readable string" do
      report = Pulse.generate()
      assert is_binary(report.summary)
      assert report.summary =~ "Pulse:"
    end

    test "includes active goals" do
      {:ok, _} = Graph.add_node(node_attrs(%{node_type: :goal, status: :active}))
      report = Pulse.generate()
      assert length(report.active_goals) == 1
    end

    test "identifies coverage gaps (goals with no action/outcome)" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal}))
      {:ok, obs} = Graph.add_node(node_attrs(%{node_type: :observation, title: "Obs"}))
      {:ok, _} = Graph.add_edge(goal.id, obs.id, :leads_to)

      report = Pulse.generate()
      gap_ids = Enum.map(report.coverage_gaps, & &1.id)
      assert goal.id in gap_ids
    end

    test "goals with action children are not coverage gaps" do
      {:ok, goal} = Graph.add_node(node_attrs(%{node_type: :goal}))
      {:ok, action} = Graph.add_node(node_attrs(%{node_type: :action, title: "Act"}))
      {:ok, _} = Graph.add_edge(goal.id, action.id, :leads_to)

      report = Pulse.generate()
      gap_ids = Enum.map(report.coverage_gaps, & &1.id)
      refute goal.id in gap_ids
    end

    test "finds low-confidence nodes" do
      {:ok, _} = Graph.add_node(node_attrs(%{confidence: 30, title: "Low"}))
      {:ok, _} = Graph.add_node(node_attrs(%{confidence: 80, title: "High"}))

      report = Pulse.generate()
      assert length(report.low_confidence) == 1
      assert hd(report.low_confidence).confidence == 30
    end

    test "respects custom confidence threshold" do
      {:ok, _} = Graph.add_node(node_attrs(%{confidence: 70, title: "Medium"}))

      report_default = Pulse.generate()
      report_high = Pulse.generate(confidence_threshold: 80)

      assert length(report_default.low_confidence) == 0
      assert length(report_high.low_confidence) == 1
    end
  end
end
