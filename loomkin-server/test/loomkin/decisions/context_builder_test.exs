defmodule Loomkin.Decisions.ContextBuilderTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{Graph, ContextBuilder}
  alias Loomkin.Schemas.Session

  defp node_attrs(overrides) do
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

    test "includes active goals for the session" do
      session = create_session()
      {:ok, _} = Graph.add_node(node_attrs(%{title: "Ship feature X", session_id: session.id}))

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Ship feature X"
    end

    test "truncates when over max_tokens budget" do
      session = create_session()

      for i <- 1..50 do
        Graph.add_node(
          node_attrs(%{
            title: "Goal #{i} with a very long title to use up space",
            description: String.duplicate("x", 200),
            session_id: session.id
          })
        )
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

    test "truncation still works with prior attempts section included" do
      session = create_session()

      for i <- 1..20 do
        Graph.add_node(
          node_attrs(%{
            node_type: :revisit,
            title: "Revisit item #{i} with long title padding",
            status: :active
          })
        )
      end

      for i <- 1..20 do
        Graph.add_node(
          node_attrs(%{
            node_type: :decision,
            title: "Abandoned decision #{i} with long title padding",
            status: :abandoned
          })
        )
      end

      assert {:ok, result} = ContextBuilder.build(session.id, max_tokens: 64)
      max_chars = 64 * 4
      assert byte_size(result) <= max_chars
      assert result =~ "[truncated...]"
    end
  end

  describe "prior attempts section" do
    test "includes revisit nodes" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :revisit,
            title: "Retry caching strategy",
            confidence: 40,
            status: :active
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "## Prior Attempts & Lessons"
      assert result =~ "[REVISIT] Retry caching strategy (confidence: 40) — needs re-evaluation"
    end

    test "includes abandoned nodes" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :decision,
            title: "Use Redis",
            description: "Too complex for current scale",
            status: :abandoned
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "[ABANDONED] Use Redis — Too complex for current scale"
    end

    test "includes superseded nodes" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :decision,
            title: "Old API design",
            status: :superseded
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "[SUPERSEDED] Old API design → replaced"
    end

    test "omits section header when no prior attempts exist" do
      session = create_session()
      assert {:ok, result} = ContextBuilder.build(session.id)
      refute result =~ "Prior Attempts & Lessons"
    end
  end

  describe "session section filtering" do
    test "excludes auto-logged nodes from session context" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Manual decision",
            node_type: :decision,
            session_id: session.id
          })
        )

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Auto tool action",
            node_type: :action,
            session_id: session.id,
            metadata: %{"auto_logged" => true}
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Manual decision"
      refute result =~ "Auto tool action"
    end

    test "session section is truncated when it exceeds per-section limit" do
      session = create_session()

      for i <- 1..100 do
        Graph.add_node(
          node_attrs(%{
            title: "Decision #{i} with enough text to fill the section budget",
            node_type: :decision,
            session_id: session.id
          })
        )
      end

      assert {:ok, result} = ContextBuilder.build(session.id, max_tokens: 8192)
      # The session section should be internally truncated even if total budget is large
      session_section = result |> String.split("## Session Context\n") |> List.last()
      assert byte_size(session_section) <= 1024 + 50
    end
  end

  describe "cross-session goals" do
    test "cross_session: false only shows goals for the current session" do
      session = create_session()
      other_session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Session-bound goal",
            session_id: session.id
          })
        )

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Other session goal",
            session_id: other_session.id
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Session-bound goal"
      refute result =~ "Other session goal"
    end

    test "cross_session: true includes goals from all sessions" do
      session = create_session()
      other_session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Goal A",
            session_id: session.id
          })
        )

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Goal B",
            session_id: other_session.id
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id, cross_session: true)
      assert result =~ "Goal A"
      assert result =~ "Goal B"
    end
  end

  describe "keeper references" do
    test "includes keeper_id in goal output" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Goal with keeper",
            session_id: session.id,
            metadata: %{"keeper_id" => "keeper-abc-123"}
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Goal with keeper"
      assert result =~ "Deep context available in keeper keeper-abc-123"
    end

    test "includes keeper_id in decision output" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :decision,
            title: "Decision with keeper",
            metadata: %{"keeper_id" => "keeper-def-456"}
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Deep context available in keeper keeper-def-456"
    end

    test "includes keeper_id in prior attempts output" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            node_type: :decision,
            title: "Abandoned with keeper",
            status: :abandoned,
            metadata: %{"keeper_id" => "keeper-ghi-789"}
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "[ABANDONED] Abandoned with keeper"
      assert result =~ "Deep context available in keeper keeper-ghi-789"
    end

    test "omits keeper reference when metadata has no keeper_id" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Goal without keeper",
            session_id: session.id,
            metadata: %{"some_other" => "value"}
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Goal without keeper"
      refute result =~ "Deep context available in keeper"
    end

    test "omits keeper reference when metadata is empty" do
      session = create_session()

      {:ok, _} =
        Graph.add_node(
          node_attrs(%{
            title: "Goal empty metadata",
            session_id: session.id
          })
        )

      assert {:ok, result} = ContextBuilder.build(session.id)
      assert result =~ "Goal empty metadata"
      refute result =~ "Deep context available in keeper"
    end
  end
end
