defmodule Loomkin.Orchestration.SessionBridgeComplexTaskTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.SessionBridge
  alias Loomkin.Orchestration.Schema.Epic
  alias Loomkin.Orchestration.LLM.Stub
  alias Loomkin.Repo

  setup do
    start_supervised!(Stub)
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    # The application-supervised KnowledgeStore needs sandbox access too if
    # the orchestrator pulls it during dispatch. The SessionBridge itself now
    # persists the Epic row before submitting, so the SwarmCoordinator (which
    # spawns the orchestrator that may write phase updates) must share the
    # test's sandbox connection.
    for pid <-
          [
            Process.whereis(Loomkin.Orchestration.KnowledgeStore),
            Process.whereis(Loomkin.Orchestration.SwarmCoordinator),
            Process.whereis(Loomkin.Orchestration.Curator)
          ],
        is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)
    end

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  describe "dispatch/3 for :complex_task (rule-classified)" do
    test "persists an Epic with session metadata and returns {:complex_task, epic_id}" do
      session_state = %{id: "sess-1", team_id: nil, workspace_id: nil}
      message = "refactor lib/loomkin/session/session.ex to use gen_statem"

      result = SessionBridge.dispatch(session_state, message)

      assert {:complex_task, epic_id} = result
      assert is_binary(epic_id)

      epic = Repo.get(Epic, epic_id)
      assert %Epic{} = epic
      assert epic.spec == message
      assert epic.title == "refactor lib/loomkin/session/session.ex to use gen_statem"
      assert epic.created_by == "sess-1"

      # Ecto returns map fields with string keys after a round-trip through
      # the DB, so normalize before asserting.
      session_id =
        Map.get(epic.metadata, :session_id) || Map.get(epic.metadata, "session_id")

      assert session_id == "sess-1"
      assert Map.has_key?(epic.metadata, :team_id) or Map.has_key?(epic.metadata, "team_id")

      assert Map.has_key?(epic.metadata, :workspace_id) or
               Map.has_key?(epic.metadata, "workspace_id")
    end
  end

  describe "dispatch/3 for :complex_task (LLM-classified)" do
    test "ambiguous message routed via LLM stub also persists an Epic with session metadata" do
      Stub.queue([
        {:by_reviewer, :intent_classifier,
         ~s({"intent":"complex_task","confidence":"high","rationale":"sounds like work"})}
      ])

      session_state = %{id: "sess-llm", team_id: nil, workspace_id: nil}
      message = "I'm thinking about the architecture and want to talk through tradeoffs"

      result = SessionBridge.dispatch(session_state, message)

      assert {:complex_task, epic_id} = result
      assert is_binary(epic_id)

      epic = Repo.get(Epic, epic_id)
      assert %Epic{} = epic
      assert epic.spec == message
      assert epic.created_by == "sess-llm"

      session_id =
        Map.get(epic.metadata, :session_id) || Map.get(epic.metadata, "session_id")

      assert session_id == "sess-llm"
    end
  end
end
