defmodule Loomkin.Teams.PriorityRouterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.PriorityRouter

  describe "classify/1 urgent" do
    test "abort_task is urgent" do
      assert {:urgent, :abort_task} = PriorityRouter.classify({:abort_task, "reason"})
    end

    test "budget_exceeded is urgent" do
      assert {:urgent, :budget_exceeded} = PriorityRouter.classify({:budget_exceeded, :team})
    end

    test "file_conflict is urgent" do
      assert {:urgent, :file_conflict} =
               PriorityRouter.classify({:file_conflict, %{file: "foo.ex"}})
    end
  end

  describe "classify/1 high" do
    test "task_assigned is high" do
      assert {:high, :task_assigned} = PriorityRouter.classify({:task_assigned, "t1", "agent-1"})
    end

    test "tasks_unblocked is high" do
      assert {:high, :tasks_unblocked} = PriorityRouter.classify({:tasks_unblocked, ["t1", "t2"]})
    end

    test "confidence_warning is high" do
      assert {:high, :confidence_warning} =
               PriorityRouter.classify(
                 {:confidence_warning,
                  %{
                    source_title: "Use Redis",
                    source_confidence: 20,
                    affected_title: "Cache impl",
                    keeper_id: nil
                  }}
               )
    end

    test "review_response is high" do
      assert {:high, :review_response} =
               PriorityRouter.classify({:review_response, "reviewer", %{approved: true}})
    end

    test "plan_revision is high" do
      assert {:high, :plan_revision} = PriorityRouter.classify({:plan_revision, %{changes: []}})
    end
  end

  describe "classify/1 normal" do
    test "context_update is normal" do
      assert {:normal, :context_update} = PriorityRouter.classify({:context_update, "from", %{}})
    end

    test "peer_message is normal" do
      assert {:normal, :peer_message} =
               PriorityRouter.classify({:peer_message, "from", "content"})
    end

    test "query is normal" do
      assert {:normal, :query} = PriorityRouter.classify({:query, "id", "from", "question", []})
    end

    test "query_answer is normal" do
      assert {:normal, :query_answer} =
               PriorityRouter.classify({:query_answer, "id", "from", "answer", []})
    end

    test "keeper_created is normal" do
      assert {:normal, :keeper_created} = PriorityRouter.classify({:keeper_created, %{id: "k1"}})
    end

    test "sub_team_completed is normal" do
      assert {:normal, :sub_team_completed} =
               PriorityRouter.classify({:sub_team_completed, "sub-team-1"})
    end

    test "discovery_relevant is normal" do
      assert {:normal, :discovery_relevant} =
               PriorityRouter.classify({:discovery_relevant, %{observation_title: "obs"}})
    end

    test "request_review is normal" do
      assert {:normal, :request_review} =
               PriorityRouter.classify({:request_review, "from", %{file: "f.ex", changes: "c"}})
    end

    test "debate messages are normal" do
      assert {:normal, :debate_start} =
               PriorityRouter.classify({:debate_start, "id", "topic", ["a", "b"]})

      assert {:normal, :debate_propose} =
               PriorityRouter.classify({:debate_propose, "id", 1, "topic"})

      assert {:normal, :debate_critique} =
               PriorityRouter.classify({:debate_critique, "id", 1, []})

      assert {:normal, :debate_revise} =
               PriorityRouter.classify({:debate_revise, "id", 1, []})

      assert {:normal, :debate_vote} =
               PriorityRouter.classify({:debate_vote, "id", []})
    end

    test "pair messages are normal" do
      assert {:normal, :pair_started} =
               PriorityRouter.classify({:pair_started, "id", :coder, "partner"})

      assert {:normal, :pair_stopped} =
               PriorityRouter.classify({:pair_stopped, "id"})

      assert {:normal, :pair_event} =
               PriorityRouter.classify(
                 {:pair_event, %{event: :file_edited, from: "a", payload: %{}}}
               )
    end
  end

  describe "classify/1 ignore" do
    test "agent_status is ignored" do
      assert {:ignore, :agent_status} = PriorityRouter.classify({:agent_status, "name", :idle})
    end

    test "role_changed is ignored" do
      assert {:ignore, :role_changed} =
               PriorityRouter.classify({:role_changed, "name", :coder, :lead})
    end

    test "role_change_request is ignored" do
      assert {:ignore, :role_change_request} =
               PriorityRouter.classify({:role_change_request, "n", :a, :b, "id"})
    end
  end

  describe "classify/1 unknown" do
    test "unknown tuple messages default to normal" do
      assert {:normal, :something_new} = PriorityRouter.classify({:something_new, "data"})
    end

    test "non-tuple messages return normal unknown" do
      assert {:normal, :unknown} = PriorityRouter.classify("not a tuple")
      assert {:normal, :unknown} = PriorityRouter.classify(42)
    end

    test "empty tuple returns normal unknown instead of crashing" do
      assert {:normal, :unknown} = PriorityRouter.classify({})
    end
  end
end
