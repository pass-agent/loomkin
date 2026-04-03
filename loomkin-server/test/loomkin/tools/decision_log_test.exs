defmodule Loomkin.Tools.DecisionLogTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Tools.DecisionLog
  alias Loomkin.Decisions.Graph

  test "action metadata is correct" do
    assert DecisionLog.name() == "decision_log"
    assert is_binary(DecisionLog.description())
  end

  test "logs a simple decision node" do
    params = %{"node_type" => "goal", "title" => "Build auth system"}
    assert {:ok, %{result: msg}} = DecisionLog.run(params, %{})
    assert msg =~ "goal: Build auth system"
    assert msg =~ "id:"
  end

  test "logs a node with parent edge" do
    {:ok, parent} = Graph.add_node(%{node_type: :goal, title: "Parent"})

    params = %{
      "node_type" => "action",
      "title" => "Implement login",
      "parent_id" => parent.id,
      "edge_type" => "leads_to"
    }

    assert {:ok, %{result: msg}} = DecisionLog.run(params, %{})
    assert msg =~ "linked to #{parent.id} via leads_to"
  end

  test "logs node with description and confidence" do
    params = %{
      "node_type" => "decision",
      "title" => "Use JWT",
      "description" => "JWT for stateless auth",
      "confidence" => 85
    }

    assert {:ok, %{result: msg}} = DecisionLog.run(params, %{})
    assert msg =~ "decision: Use JWT"
  end

  test "returns error for invalid node_type" do
    params = %{"node_type" => "invalid", "title" => "Test"}

    assert {:error, msg} = DecisionLog.run(params, %{})
    assert msg =~ "Invalid node_type"
  end
end
