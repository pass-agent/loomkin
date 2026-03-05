defmodule Loomkin.Decisions.WriteupTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.Writeup

  alias Loomkin.Schemas.Session

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  defp create_session do
    %Session{}
    |> Session.changeset(%{model: "test-model", project_path: "/tmp/test"})
    |> Repo.insert!()
  end

  describe "generate/1" do
    test "generates writeup with all sections from a graph" do
      {:ok, goal} =
        Graph.add_node(node_attrs(%{title: "Fix auth bug", description: "Users can't login"}))

      {:ok, decision} =
        Graph.add_node(node_attrs(%{node_type: :decision, title: "Token vs Session"}))

      {:ok, option_a} = Graph.add_node(node_attrs(%{node_type: :option, title: "JWT tokens"}))

      {:ok, option_b} =
        Graph.add_node(node_attrs(%{node_type: :option, title: "Server sessions"}))

      {:ok, action} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Implement JWT refresh"}))

      {:ok, outcome} =
        Graph.add_node(node_attrs(%{node_type: :outcome, title: "Auth latency reduced by 50%"}))

      {:ok, _} = Graph.add_edge(goal.id, decision.id, :leads_to)
      {:ok, _} = Graph.add_edge(decision.id, option_a.id, :chosen)
      {:ok, _} = Graph.add_edge(decision.id, option_b.id, :rejected)
      {:ok, _} = Graph.add_edge(option_a.id, action.id, :leads_to)
      {:ok, _} = Graph.add_edge(action.id, outcome.id, :leads_to)

      {:ok, markdown} = Writeup.generate(title: "Fix Auth")

      assert markdown =~ "# Fix Auth"
      assert markdown =~ "## Summary"
      assert markdown =~ "Fix auth bug"
      assert markdown =~ "## Key Decisions"
      assert markdown =~ "Token vs Session"
      assert markdown =~ "[x] JWT tokens"
      assert markdown =~ "[ ] Server sessions"
      assert markdown =~ "## Implementation"
      assert markdown =~ "Implement JWT refresh"
      assert markdown =~ "## Results"
      assert markdown =~ "Auth latency reduced by 50%"
      assert markdown =~ "## Test Plan"
    end

    test "scopes by root_ids using BFS" do
      {:ok, root} = Graph.add_node(node_attrs(%{title: "Root goal"}))
      {:ok, child} = Graph.add_node(node_attrs(%{node_type: :action, title: "Child action"}))

      {:ok, _unrelated} =
        Graph.add_node(node_attrs(%{node_type: :action, title: "Unrelated action"}))

      {:ok, _} = Graph.add_edge(root.id, child.id, :leads_to)

      {:ok, markdown} = Writeup.generate(root_ids: [root.id])

      assert markdown =~ "Root goal"
      assert markdown =~ "Child action"
      refute markdown =~ "Unrelated action"
    end

    test "scopes by team_id" do
      team_id = Ecto.UUID.generate()

      {:ok, _} =
        Graph.add_node(node_attrs(%{title: "Team goal", metadata: %{"team_id" => team_id}}))

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{title: "Other goal", metadata: %{"team_id" => Ecto.UUID.generate()}})
        )

      {:ok, markdown} = Writeup.generate(team_id: team_id)

      assert markdown =~ "Team goal"
      refute markdown =~ "Other goal"
    end

    test "scopes by session_id" do
      session1 = create_session()
      session2 = create_session()

      {:ok, _} = Graph.add_node(node_attrs(%{title: "Session goal", session_id: session1.id}))

      {:ok, _} =
        Graph.add_node(node_attrs(%{title: "Other session goal", session_id: session2.id}))

      {:ok, markdown} = Writeup.generate(session_id: session1.id)

      assert markdown =~ "Session goal"
      refute markdown =~ "Other session goal"
    end

    test "includes prior attempts for superseded nodes" do
      {:ok, _old} = Graph.add_node(node_attrs(%{title: "Old approach", status: :superseded}))
      {:ok, _new} = Graph.add_node(node_attrs(%{title: "New approach"}))

      # Default collects active nodes only, so use root_ids to include superseded
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Abandoned idea", status: :abandoned}))

      # Use team_id to get all statuses
      team_id = Ecto.UUID.generate()

      {:ok, _} =
        Graph.add_node(node_attrs(%{title: "Active goal", metadata: %{"team_id" => team_id}}))

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{title: "Old way", status: :superseded, metadata: %{"team_id" => team_id}})
        )

      {:ok, markdown} = Writeup.generate(team_id: team_id)

      assert markdown =~ "## Prior Attempts"
      assert markdown =~ "~~Old way~~ (superseded)"
    end

    test "excludes test plan when include_test_plan is false" do
      {:ok, _} = Graph.add_node(node_attrs(%{title: "A goal"}))

      {:ok, markdown} = Writeup.generate(include_test_plan: false)

      refute markdown =~ "## Test Plan"
    end

    test "handles empty graph gracefully" do
      {:ok, markdown} = Writeup.generate()

      assert markdown =~ "# Pull Request"
      refute markdown =~ "## Summary"
      refute markdown =~ "## Key Decisions"
    end

    test "includes observations in summary" do
      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :observation,
            title: "Memory usage high",
            description: "Peak at 2GB"
          })
        )

      {:ok, markdown} = Writeup.generate()

      assert markdown =~ "Memory usage high"
      assert markdown =~ "Peak at 2GB"
    end
  end
end
