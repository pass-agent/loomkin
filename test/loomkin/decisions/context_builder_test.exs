defmodule Loomkin.Decisions.ContextBuilderTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Graph, ContextBuilder}
  alias Loomkin.Schemas.Session

  defp node_attrs(overrides \\ %{}) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  defp create_session do
    %Session{}
    |> Session.changeset(%{model: "test-model", project_path: "/tmp/test"})
    |> Repo.insert!()
  end

  describe "build/2" do
    test "returns formatted context string" do
      session = create_session()
      assert {:ok, result} = ContextBuilder.build(session.id)

      assert is_binary(result)
      assert result =~ "Active Goals"
      assert result =~ "Recent Decisions"
      assert result =~ "Session Context"
    end

    test "includes active goals" do
      session = create_session()
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Ship feature X"}))

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Ship feature X"
    end

    test "truncates when over max_tokens budget" do
      session = create_session()

      for i <- 1..50 do
        Graph.add_node(node_attrs(%{
          title: "Goal #{i} with a very long title to use up space",
          description: String.duplicate("x", 200)
        }))
      end

      assert {:ok, result} = ContextBuilder.build(session.id, max_tokens: 64)
      max_chars = 64 * 4
      assert byte_size(result) <= max_chars
      assert result =~ "[truncated...]"
    end

    test "does not truncate when within budget" do
      session = create_session()
      assert {:ok, result} = ContextBuilder.build(session.id, max_tokens: 4096)
      refute result =~ "[truncated...]"
    end
  end
end
