defmodule Loomkin.Tools.IntrospectDecisionHistoryTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Decisions.Graph
  alias Loomkin.Tools.IntrospectDecisionHistory

  defp node_attrs(overrides) do
    Map.merge(
      %{node_type: :decision, title: "Test decision", metadata: %{"team_id" => "team-1"}},
      overrides
    )
  end

  defp context(team_id, agent_name \\ "test-agent") do
    %{team_id: team_id, agent_name: agent_name}
  end

  describe "run/2" do
    test "returns empty message when no decisions exist" do
      params = %{team_id: "team-empty", query: "What happened?"}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-empty"))

      assert result =~ "No decision history found"
    end

    test "returns decision history for team" do
      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Use GenServer for state",
            agent_name: "test-agent",
            metadata: %{"team_id" => "team-hist"}
          })
        )

      params = %{team_id: "team-hist", query: "What decisions were made?"}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-hist"))

      assert result =~ "Use GenServer for state"
      assert result =~ "Pattern Analysis"
    end

    test "detects repeated decisions as potential circular reasoning" do
      for _ <- 1..3 do
        Graph.add_node(
          node_attrs(%{
            title: "Retry compilation",
            agent_name: "test-agent",
            metadata: %{"team_id" => "team-circ"}
          })
        )
      end

      params = %{team_id: "team-circ", query: "Am I going in circles?"}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-circ"))

      assert result =~ "Repeated decisions detected"
      assert result =~ "Retry compilation"
      assert result =~ "3x"
    end

    test "filters by agent name" do
      Graph.add_node(
        node_attrs(%{
          title: "My decision",
          agent_name: "coder-a",
          metadata: %{"team_id" => "team-filter"}
        })
      )

      Graph.add_node(
        node_attrs(%{
          title: "Other decision",
          agent_name: "coder-b",
          metadata: %{"team_id" => "team-filter"}
        })
      )

      params = %{team_id: "team-filter", query: "my decisions"}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-filter", "coder-a"))

      assert result =~ "My decision"
      refute result =~ "Other decision"
    end

    test "includes confidence analysis" do
      Graph.add_node(
        node_attrs(%{
          title: "High confidence choice",
          confidence: 90,
          agent_name: "test-agent",
          metadata: %{"team_id" => "team-conf"}
        })
      )

      params = %{team_id: "team-conf", query: "decisions"}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-conf"))

      assert result =~ "confidence=90%"
      assert result =~ "Average confidence"
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        Graph.add_node(
          node_attrs(%{
            title: "Decision #{i}",
            agent_name: "test-agent",
            metadata: %{"team_id" => "team-limit"}
          })
        )
      end

      params = %{team_id: "team-limit", query: "decisions", limit: 2}

      assert {:ok, %{result: result}} =
               IntrospectDecisionHistory.run(params, context("team-limit"))

      assert result =~ "Total decisions: 2"
    end
  end
end
