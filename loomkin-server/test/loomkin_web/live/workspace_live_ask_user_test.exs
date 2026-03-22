defmodule LoomkinWeb.Live.WorkspaceLiveAskUserTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  # ---------------------------------------------------------------------------
  # Task 1: WorkspaceLive — batched pending_questions and let_team_decide event
  # ---------------------------------------------------------------------------

  describe "let_team_decide event" do
    test "let_team_decide: calls handle_collective_decision for every pending question for agent" do
      # Build a socket with two pending questions for "researcher"
      q1 = build_question("q1", "researcher", "Use tool A?", ["Yes", "No"])
      q2 = build_question("q2", "researcher", "Use tool B?", ["Yes", "No"])

      socket = build_test_socket(agent_name: "researcher", pending_questions: [q1, q2])

      # handle_event should not raise, and should clear the agent's questions
      {:noreply, updated_socket} =
        WorkspaceLive.handle_event("let_team_decide", %{"agent" => "researcher"}, socket)

      remaining = updated_socket.assigns.pending_questions
      assert Enum.filter(remaining, &(&1.agent_name == "researcher")) == []
    end

    test "let_team_decide: resolves all batched questions for agent simultaneously" do
      q1 = build_question("batch-q1", "analyst", "Option A?", ["X", "Y"])
      q2 = build_question("batch-q2", "analyst", "Option B?", ["X", "Y"])
      other = build_question("other-q", "other-agent", "Unrelated?", ["A", "B"])

      socket =
        build_test_socket(agent_name: "analyst", pending_questions: [q1, q2, other])

      {:noreply, updated_socket} =
        WorkspaceLive.handle_event("let_team_decide", %{"agent" => "analyst"}, socket)

      # other agent's question should remain
      remaining = updated_socket.assigns.pending_questions
      assert length(remaining) == 1
      assert hd(remaining).agent_name == "other-agent"
    end

    test "let_team_decide: clears agent card pending_questions list" do
      q1 = build_question("card-q1", "researcher", "Something?", ["Yes", "No"])

      socket = build_test_socket(agent_name: "researcher", pending_questions: [q1])

      {:noreply, updated_socket} =
        WorkspaceLive.handle_event("let_team_decide", %{"agent" => "researcher"}, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, "researcher"])
      assert card[:pending_questions] == []
    end
  end

  describe "handle_info :ask_user_question — batched questions" do
    test "appends to agent card pending_questions when card already has a question" do
      q1 = build_question("existing-q1", "researcher", "First question?", ["Yes", "No"])
      q2 = build_question("new-q2", "researcher", "Second question?", ["A", "B"])

      # Card already has q1 in its pending_questions list
      socket =
        build_test_socket(
          agent_name: "researcher",
          pending_questions: [q1],
          card_pending_questions: [q1]
        )

      {:noreply, updated_socket} = WorkspaceLive.handle_info({:ask_user_question, q2}, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, "researcher"])
      assert length(card[:pending_questions]) == 2
    end

    test "stores question as list in agent card pending_questions field" do
      q = build_question("q-list", "worker", "Do something?", ["Yes", "No"])

      socket = build_test_socket(agent_name: "worker", pending_questions: [])

      {:noreply, updated_socket} = WorkspaceLive.handle_info({:ask_user_question, q}, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, "worker"])
      assert is_list(card[:pending_questions])
      assert length(card[:pending_questions]) == 1
    end
  end

  describe "handle_info :ask_user_answered — clears answered question" do
    test "removes answered question from pending_questions and clears card when last question" do
      q = build_question("answered-q1", "researcher", "Clear this?", ["Yes", "No"])

      socket =
        build_test_socket(
          agent_name: "researcher",
          pending_questions: [q],
          card_pending_questions: [q]
        )

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info({:ask_user_answered, "answered-q1", "Yes"}, socket)

      assert updated_socket.assigns.pending_questions == []

      card = get_in(updated_socket.assigns, [:agent_cards, "researcher"])
      assert card[:pending_questions] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Task 2: AgentCardComponent — cyan panel, status dot/label, card_state_class
  # ---------------------------------------------------------------------------

  describe "ask_user card rendering" do
    test "ask_user card: status dot class is bg-cyan-500 animate-pulse when :ask_user_pending" do
      result = LoomkinWeb.AgentCardComponent.status_dot_class_for_test(:ask_user_pending)
      assert result == "bg-cyan-500 animate-pulse"
    end

    test "ask_user card: status label is 'Waiting for you' when :ask_user_pending" do
      result = LoomkinWeb.AgentCardComponent.status_label_for_test(:ask_user_pending)
      assert result == "Waiting for you"
    end

    test "ask_user card: card_state_class returns 'agent-card-asking' for :ask_user_pending" do
      result = LoomkinWeb.AgentCardComponent.card_state_class_for_test(:idle, :ask_user_pending)
      assert result == "agent-card-asking"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_question(question_id, agent_name, question, options) do
    %{
      question_id: question_id,
      agent_name: agent_name,
      question: question,
      options: options,
      team_id: "team-test"
    }
  end

  defp build_test_socket(opts) do
    agent_name = Keyword.get(opts, :agent_name, "test-agent")
    pending_questions = Keyword.get(opts, :pending_questions, [])
    card_pending_questions = Keyword.get(opts, :card_pending_questions, [])

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
        flash: %{},
        live_action: :show,
        team_id: "team-test",
        active_team_id: "team-test",
        active_tab: nil,
        leader_approval_pending: nil,
        cached_agents: [],
        pending_questions: pending_questions,
        activity_event_count: 0,
        activity_known_agents: [],
        buffered_activity_events: [],
        agent_cards: %{
          agent_name => %{
            name: agent_name,
            role: :peer,
            status: :ask_user_pending,
            pending_questions: card_pending_questions,
            pending_question: nil
          }
        }
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
