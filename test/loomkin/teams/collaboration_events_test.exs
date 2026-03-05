defmodule Loomkin.Teams.CollaborationEventsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{CollaborationEvents, Comms, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "collab-events-test")
    Comms.subscribe(team_id, "test-listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "discovery_shared/4" do
    test "broadcasts collab_event with discovery_shared type", %{team_id: team_id} do
      CollaborationEvents.discovery_shared(team_id, "researcher", ["coder"], :file_analysis)

      assert_receive {:collab_event, payload}
      assert payload.type == :discovery_shared
      assert payload.agents == ["researcher", "coder"]
      assert payload.description =~ "researcher shared a file_analysis discovery with coder"
      assert payload.metadata.from == "researcher"
      assert payload.metadata.to == ["coder"]
      assert %DateTime{} = payload.timestamp
    end

    test "formats multiple recipients", %{team_id: team_id} do
      CollaborationEvents.discovery_shared(
        team_id,
        "researcher",
        ["coder", "tester", "lead"],
        :bug
      )

      assert_receive {:collab_event, payload}
      assert payload.description =~ "coder, tester, and lead"
    end
  end

  describe "question_asked/4" do
    test "broadcasts collab_event with question", %{team_id: team_id} do
      CollaborationEvents.question_asked(
        team_id,
        "coder",
        "researcher",
        "How does the auth module work?"
      )

      assert_receive {:collab_event, payload}
      assert payload.type == :question_asked
      assert payload.agents == ["coder", "researcher"]
      assert payload.description =~ "coder asked researcher"
      assert payload.description =~ "auth module"
      assert payload.metadata.from == "coder"
      assert payload.metadata.to == "researcher"
    end

    test "truncates long questions", %{team_id: team_id} do
      long_question = String.duplicate("x", 500)
      CollaborationEvents.question_asked(team_id, "a", "b", long_question)

      assert_receive {:collab_event, payload}
      assert String.length(payload.metadata.question) <= 200
    end
  end

  describe "question_answered/4" do
    test "broadcasts collab_event with question_answered type", %{team_id: team_id} do
      CollaborationEvents.question_answered(team_id, "researcher", "coder", "q-123")

      assert_receive {:collab_event, payload}
      assert payload.type == :question_answered
      assert payload.agents == ["researcher", "coder"]
      assert payload.description =~ "researcher answered coder's question"
      assert payload.metadata.query_id == "q-123"
    end
  end

  describe "task_rebalanced/4" do
    test "broadcasts collab_event with task_rebalanced type", %{team_id: team_id} do
      CollaborationEvents.task_rebalanced(team_id, "task-42", "coder", "tester")

      assert_receive {:collab_event, payload}
      assert payload.type == :task_rebalanced
      assert payload.agents == ["coder", "tester"]
      assert payload.description =~ "reassigned from coder to tester"
      assert payload.metadata.task_id == "task-42"
    end
  end

  describe "conflict_detected/4" do
    test "broadcasts collab_event with conflict_detected type", %{team_id: team_id} do
      CollaborationEvents.conflict_detected(team_id, "coder", "researcher", :file_overlap)

      assert_receive {:collab_event, payload}
      assert payload.type == :conflict_detected
      assert payload.agents == ["coder", "researcher"]
      assert payload.description =~ "Conflict detected between coder and researcher"
      assert payload.metadata.conflict_type == :file_overlap
    end
  end

  describe "consensus_reached/3" do
    test "broadcasts collab_event with consensus_reached type", %{team_id: team_id} do
      CollaborationEvents.consensus_reached(team_id, "Use GenServer pattern", 0.85)

      assert_receive {:collab_event, payload}
      assert payload.type == :consensus_reached
      assert payload.description =~ "Team voted: Use GenServer pattern"
      assert payload.description =~ "0.85"
      assert payload.metadata.weighted_score == 0.85
    end
  end

  describe "knowledge_propagated/3" do
    test "broadcasts collab_event with knowledge_propagated type", %{team_id: team_id} do
      CollaborationEvents.knowledge_propagated(team_id, "sub-team-abc123", :architecture)

      assert_receive {:collab_event, payload}
      assert payload.type == :knowledge_propagated
      assert payload.description =~ "architecture"
      assert payload.description =~ "propagated from sub-team"
      assert payload.metadata.source_team_id == "sub-team-abc123"
    end
  end
end
