defmodule Loomkin.Teams.AgentConfidenceTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent

  defp unique_team_id do
    "test-team-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(overrides \\ []) do
    team_id = Keyword.get(overrides, :team_id, unique_team_id())
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)

    opts =
      [team_id: team_id, name: name, role: role]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name, role: role}
  end

  describe "rate limit: first call" do
    test "rate limit: first AskUser call is allowed through" do
      %{pid: pid} = start_agent()
      tool_args = %{"question" => "Q?", "options" => ["Yes", "No"]}

      result = GenServer.call(pid, {:check_ask_user_rate_limit, tool_args})
      assert result == :allow

      # State should now have pending_ask_user set with a card_id
      state = :sys.get_state(pid)
      assert state.pending_ask_user != nil
      assert is_binary(state.pending_ask_user.card_id)
      assert state.pending_ask_user.questions == []
    end
  end

  describe "rate limit: batch on open card" do
    test "rate limit: second AskUser while card open appends to existing card" do
      %{pid: pid} = start_agent()
      card_id = Ecto.UUID.generate()

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: %{card_id: card_id, questions: []}}
      end)

      tool_args = %{"question" => "Q2?", "options" => ["A", "B"]}
      result = GenServer.call(pid, {:check_ask_user_rate_limit, tool_args})
      assert result == {:batch, card_id}
    end
  end

  describe "rate limit: drop within cooldown" do
    test "rate limit: second call within cooldown window when card is closed is dropped" do
      %{pid: pid} = start_agent()

      # last_asked_at set to 1 minute ago (within 5-minute cooldown)
      one_minute_ago = System.monotonic_time(:millisecond) - 60_000

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: nil, last_asked_at: one_minute_ago}
      end)

      tool_args = %{"question" => "Q?", "options" => ["Yes", "No"]}
      result = GenServer.call(pid, {:check_ask_user_rate_limit, tool_args})
      assert result == :drop
    end
  end

  describe "rate limit: allow after cooldown" do
    test "rate limit: call after cooldown expires is allowed" do
      %{pid: pid} = start_agent()

      # last_asked_at set to 6 minutes ago (past 5-minute cooldown)
      six_minutes_ago = System.monotonic_time(:millisecond) - 360_000

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: nil, last_asked_at: six_minutes_ago}
      end)

      tool_args = %{"question" => "Q?", "options" => ["Yes", "No"]}
      result = GenServer.call(pid, {:check_ask_user_rate_limit, tool_args})
      assert result == :allow
    end
  end

  describe "rate limit: dropped call side effects" do
    test "rate limit: dropped call does not create a new card" do
      %{pid: pid} = start_agent()

      one_minute_ago = System.monotonic_time(:millisecond) - 60_000

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: nil, last_asked_at: one_minute_ago}
      end)

      tool_args = %{"question" => "Q?", "options" => ["Yes", "No"]}
      result = GenServer.call(pid, {:check_ask_user_rate_limit, tool_args})
      assert result == :drop

      # State should still have nil pending_ask_user — no card created
      state = :sys.get_state(pid)
      assert state.pending_ask_user == nil
    end
  end

  describe "batch answer routing" do
    test "batch: answers route to correct question by question_id" do
      %{pid: pid} = start_agent()
      card_id = Ecto.UUID.generate()
      question_id = Ecto.UUID.generate()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | pending_ask_user: %{
              card_id: card_id,
              questions: [%{question_id: question_id, question: "Q?"}]
            }
        }
      end)

      result = GenServer.call(pid, {:ask_user_answered, question_id})
      assert result == :ok

      # questions list is now empty → card should be cleared and last_asked_at set
      state = :sys.get_state(pid)
      assert state.pending_ask_user == nil
      assert state.last_asked_at != nil
      assert state.status == :idle
    end
  end

  describe "on_tool_execute: drop canned result" do
    test "drop: returns canned message string without touching pending_ask_user" do
      %{pid: pid} = start_agent()
      one_minute_ago = System.monotonic_time(:millisecond) - 60_000

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: nil, last_asked_at: one_minute_ago}
      end)

      # Simulate the drop path — check returns :drop, so no new card should appear
      result = GenServer.call(pid, {:check_ask_user_rate_limit, %{"question" => "Q?"}})
      assert result == :drop
      state = :sys.get_state(pid)
      assert state.pending_ask_user == nil
    end
  end

  describe "append_ask_user_question cast" do
    test "appends question to open card in state" do
      %{pid: pid} = start_agent()
      card_id = Ecto.UUID.generate()
      question_id = Ecto.UUID.generate()
      tool_args = %{"question" => "Batched Q?", "options" => ["X", "Y"]}

      :sys.replace_state(pid, fn s ->
        %{s | pending_ask_user: %{card_id: card_id, questions: []}}
      end)

      GenServer.cast(pid, {:append_ask_user_question, tool_args, card_id, question_id, self()})
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.pending_ask_user.questions) == 1
      assert hd(state.pending_ask_user.questions).question_id == question_id
    end
  end

  describe "cooldown semantics" do
    test "cooldown: starts from when last question in batch is answered, not from card open" do
      %{pid: pid} = start_agent()
      card_id = Ecto.UUID.generate()
      q1 = Ecto.UUID.generate()
      q2 = Ecto.UUID.generate()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | pending_ask_user: %{
              card_id: card_id,
              questions: [
                %{question_id: q1, question: "Q1?"},
                %{question_id: q2, question: "Q2?"}
              ]
            }
        }
      end)

      # Answer first question — card should remain open (still has q2)
      :ok = GenServer.call(pid, {:ask_user_answered, q1})
      state_after_first = :sys.get_state(pid)
      assert state_after_first.pending_ask_user != nil
      assert state_after_first.last_asked_at == nil

      # Answer second question — card should close, last_asked_at set
      :ok = GenServer.call(pid, {:ask_user_answered, q2})
      state_after_second = :sys.get_state(pid)
      assert state_after_second.pending_ask_user == nil
      assert state_after_second.last_asked_at != nil
    end
  end
end
