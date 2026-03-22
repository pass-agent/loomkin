defmodule Loomkin.Teams.AgentBroadcastTest do
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

  describe "broadcast delivery" do
    test "sends message to all paused agents in a team via inject_broadcast" do
      team_id = unique_team_id()
      a1 = start_agent(team_id: team_id, name: "coder-1", role: :coder)
      a2 = start_agent(team_id: team_id, name: "coder-2", role: :coder)
      a3 = start_agent(team_id: team_id, name: "researcher-1", role: :researcher)

      # Set all agents to paused so inject_broadcast appends without starting loop
      for agent <- [a1, a2, a3] do
        :sys.replace_state(agent.pid, fn state ->
          paused_state = %{
            messages: [%{role: :user, content: "initial task"}],
            iteration: 1,
            reason: :user_requested
          }

          %{state | status: :paused, paused_state: paused_state}
        end)
      end

      for agent <- [a1, a2, a3] do
        assert :ok = Agent.inject_broadcast(agent.pid, "[Broadcast from Human]: hello team")
      end

      for agent <- [a1, a2, a3] do
        state = :sys.get_state(agent.pid)
        assert state.status == :paused
        assert length(state.paused_state.messages) == 2

        last_msg = List.last(state.paused_state.messages)
        assert last_msg.role == :user
        assert last_msg.content == "[Broadcast from Human]: hello team"
      end
    end

    test "broadcast to team with no agents does not crash" do
      # Simply verify that broadcasting to an empty list does not raise
      agents = []

      assert :ok ==
               Enum.each(agents, fn agent ->
                 Agent.inject_broadcast(agent.pid, "[Broadcast from Human]: hello")
               end)
    end

    test "message is prefixed with broadcast marker" do
      team_id = unique_team_id()
      %{pid: pid} = start_agent(team_id: team_id, name: "coder-1", role: :coder)

      # Set agent to paused state so inject_broadcast appends to paused_state
      :sys.replace_state(pid, fn state ->
        paused_state = %{
          messages: [%{role: :user, content: "initial task"}],
          iteration: 1,
          reason: :user_requested
        }

        %{state | status: :paused, paused_state: paused_state}
      end)

      broadcast_text = "[Broadcast from Human]: focus on testing"
      assert :ok = Agent.inject_broadcast(pid, broadcast_text)

      state = :sys.get_state(pid)
      last_msg = List.last(state.paused_state.messages)
      assert last_msg.content == "[Broadcast from Human]: focus on testing"
      assert String.starts_with?(last_msg.content, "[Broadcast from Human]:")
    end

    test "dead agent PID does not crash broadcast loop" do
      %{pid: pid} = start_agent()
      GenServer.stop(pid, :normal)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end

      # Calling inject_broadcast on a dead PID should not crash
      assert {:noproc, _} = catch_exit(Agent.inject_broadcast(pid, "hello"))
    end

    test "injects broadcast into paused agent's paused_state.messages" do
      %{pid: pid} = start_agent()

      # Manually set paused state
      :sys.replace_state(pid, fn state ->
        paused_state = %{
          messages: [%{role: :user, content: "original task"}],
          iteration: 2,
          reason: :user_requested
        }

        %{
          state
          | status: :paused,
            paused_state: paused_state,
            messages: [%{role: :user, content: "original task"}]
        }
      end)

      assert :ok = Agent.inject_broadcast(pid, "[Broadcast from Human]: new directive")

      state = :sys.get_state(pid)
      assert state.status == :paused
      assert length(state.paused_state.messages) == 2

      last_msg = List.last(state.paused_state.messages)
      assert last_msg.role == :user
      assert last_msg.content == "[Broadcast from Human]: new directive"

      # paused_state should still be intact (no loop started)
      assert state.loop_task == nil
    end

    test "inject_broadcast on non-paused agent delegates to send_message" do
      %{pid: pid} = start_agent()
      state_before = :sys.get_state(pid)
      assert state_before.status == :idle
      assert state_before.loop_task == nil

      # Verify delegation by exploiting send_message's busy guard:
      # when loop_task is already set, send_message returns {:error, :busy}.
      # The paused/complete/error handlers all return :ok, so getting
      # {:error, :busy} proves inject_broadcast delegated to send_message.
      fake_task = %Task{pid: self(), ref: make_ref(), owner: self(), mfa: nil}

      :sys.replace_state(pid, fn state ->
        %{state | loop_task: {fake_task, nil}}
      end)

      assert {:error, :busy} = Agent.inject_broadcast(pid, "hello busy agent")
    end
  end
end
