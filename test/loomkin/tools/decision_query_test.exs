defmodule Loomkin.Tools.DecisionQueryTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Tools.DecisionQuery
  alias Loomkin.Decisions.Graph

  defp node_attrs(overrides \\ %{}) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  test "action metadata is correct" do
    assert DecisionQuery.name() == "decision_query"
    assert is_binary(DecisionQuery.description())
  end

  test "active_goals returns formatted goals" do
    {:ok, _} = Graph.add_node(node_attrs(%{title: "Ship feature"}))

    assert {:ok, %{result: result}} = DecisionQuery.run(%{"query_type" => "active_goals"}, %{})
    assert result =~ "Active Goals"
    assert result =~ "Ship feature"
  end

  test "active_goals returns none when empty" do
    assert {:ok, %{result: result}} = DecisionQuery.run(%{"query_type" => "active_goals"}, %{})
    assert result =~ "None found"
  end

  test "recent_decisions returns formatted decisions" do
    {:ok, _} = Graph.add_node(node_attrs(%{node_type: :decision, title: "Use Ecto"}))

    assert {:ok, %{result: result}} = DecisionQuery.run(%{"query_type" => "recent_decisions"}, %{})
    assert result =~ "Recent Decisions"
    assert result =~ "Use Ecto"
  end

  test "pulse returns summary" do
    assert {:ok, %{result: result}} = DecisionQuery.run(%{"query_type" => "pulse"}, %{})
    assert result =~ "Pulse:"
  end

  test "search finds matching nodes" do
    {:ok, _} = Graph.add_node(node_attrs(%{title: "Authentication module"}))
    {:ok, _} = Graph.add_node(node_attrs(%{title: "Database schema"}))

    assert {:ok, %{result: result}} =
             DecisionQuery.run(%{"query_type" => "search", "search_term" => "Auth"}, %{})

    assert result =~ "Authentication module"
    refute result =~ "Database schema"
  end

  test "search with no matches returns none" do
    assert {:ok, %{result: result}} =
             DecisionQuery.run(%{"query_type" => "search", "search_term" => "nonexistent"}, %{})

    assert result =~ "None found"
  end
end
