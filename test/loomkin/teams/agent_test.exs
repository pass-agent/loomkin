defmodule Loomkin.Teams.AgentTest do
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

  describe "start_link/1 and registration" do
    test "agent spawns and registers correctly" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      assert Process.alive?(pid)
      assert [{^pid, %{role: :coder, status: :idle}}] =
               Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, name})
    end

    test "agent shows in Registry with correct metadata" do
      %{pid: pid, team_id: team_id, name: name} = start_agent(role: :researcher)

      [{^pid, meta}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, name})
      assert meta.role == :researcher
      assert meta.status == :idle
    end

    test "returns error for unknown role" do
      opts = [team_id: unique_team_id(), name: "bad-agent", role: :nonexistent]

      assert {:error, {{:unknown_role, :nonexistent}, _}} =
               start_supervised({Agent, opts}, id: :bad_role_agent)
    end
  end

  describe "role config loading" do
    test "agent loads role config tools" do
      %{pid: pid} = start_agent(role: :coder)
      state = :sys.get_state(pid)

      assert Loomkin.Tools.FileRead in state.tools
      assert Loomkin.Tools.FileWrite in state.tools
      assert Loomkin.Tools.Shell in state.tools
    end

    test "agent loads role config model" do
      %{pid: pid} = start_agent(role: :lead)
      state = :sys.get_state(pid)

      # Under 5.7, all roles use the uniform default model
      assert state.model == Loomkin.Teams.ModelRouter.default_model()
    end

    test "researcher gets read-only tools" do
      %{pid: pid} = start_agent(role: :researcher)
      state = :sys.get_state(pid)

      assert Loomkin.Tools.FileRead in state.tools
      assert Loomkin.Tools.FileSearch in state.tools
      refute Loomkin.Tools.FileWrite in state.tools
      refute Loomkin.Tools.Shell in state.tools
    end
  end

  describe "model override" do
    test "agent with model override uses overridden model" do
      %{pid: pid} = start_agent(role: :coder, model: "openai:gpt-4o")
      state = :sys.get_state(pid)

      assert state.model == "openai:gpt-4o"
    end
  end

  describe "PubSub subscriptions" do
    test "agent subscribes to team topic" do
      %{pid: pid, team_id: team_id} = start_agent()

      # Send a message on the team topic — agent should handle it
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:context_update, "peer-1", %{info: "test data"}}
      )

      # Give it a moment to process
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.context["peer-1"] == %{info: "test data"}
    end

    test "agent subscribes to direct agent topic" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}:agent:#{name}",
        {:peer_message, "lead", "do the thing"}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.messages) == 1
      [msg] = state.messages
      assert msg.role == :user
      assert msg.content =~ "[Peer lead]"
      assert msg.content =~ "do the thing"
    end
  end

  describe "get_status/1" do
    test "returns :idle for a new agent" do
      %{pid: pid} = start_agent()
      assert :idle = Agent.get_status(pid)
    end
  end

  describe "get_history/1" do
    test "returns empty history for a new agent" do
      %{pid: pid} = start_agent()
      assert [] = Agent.get_history(pid)
    end
  end

  describe "peer_message/3" do
    test "adds peer message to conversation history" do
      %{pid: pid} = start_agent()

      Agent.peer_message(pid, "researcher", "Found the bug in line 42")
      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.content =~ "[Peer researcher]"
      assert msg.content =~ "Found the bug in line 42"
    end

    test "multiple peer messages accumulate" do
      %{pid: pid} = start_agent()

      Agent.peer_message(pid, "researcher", "msg1")
      Agent.peer_message(pid, "tester", "msg2")
      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 2
    end
  end

  describe "assign_task/2" do
    test "stores the task in state" do
      %{pid: pid} = start_agent()

      task = %{id: "task-1", description: "Fix the flaky test"}
      Agent.assign_task(pid, task)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.task == task
    end
  end

  describe "context_update via PubSub" do
    test "stores context from peers" do
      %{pid: pid, team_id: team_id} = start_agent()

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:context_update, "researcher", %{files: ["lib/foo.ex"]}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.context["researcher"] == %{files: ["lib/foo.ex"]}
    end

    test "updates replace previous context from same peer" do
      %{pid: pid, team_id: team_id} = start_agent()

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:context_update, "researcher", %{v: 1}}
      )

      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:context_update, "researcher", %{v: 2}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.context["researcher"] == %{v: 2}
    end
  end

  describe "multiple agents coexistence" do
    test "multiple agents can coexist in the same team" do
      team_id = unique_team_id()

      %{pid: pid1, name: name1} = start_agent(team_id: team_id, name: "coder-1", role: :coder)

      %{pid: pid2, name: name2} =
        start_agent(team_id: team_id, name: "researcher-1", role: :researcher)

      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      [{^pid1, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, name1})
      [{^pid2, _}] = Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, name2})

      # Both receive team-level broadcasts
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:context_update, "lead", %{plan: "do stuff"}}
      )

      Process.sleep(50)

      state1 = :sys.get_state(pid1)
      state2 = :sys.get_state(pid2)
      assert state1.context["lead"] == %{plan: "do stuff"}
      assert state2.context["lead"] == %{plan: "do stuff"}
    end
  end

  describe "agent struct defaults" do
    test "new agent has expected default values" do
      %{pid: pid} = start_agent()
      state = :sys.get_state(pid)

      assert state.messages == []
      assert state.task == nil
      assert state.context == %{}
      assert state.cost_usd == 0.0
      assert state.tokens_used == 0
      assert state.status == :idle
    end
  end
end
