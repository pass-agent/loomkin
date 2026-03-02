defmodule Loomkin.Teams.AgentQueryTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Agent, Comms, QueryRouter}

  defp unique_team_id do
    "query-test-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(overrides \\ []) do
    team_id = Keyword.get(overrides, :team_id, unique_team_id())
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)

    opts =
      [team_id: team_id, name: name, role: role]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name}
  end

  setup do
    QueryRouter.expire_stale(0)
    Process.sleep(1)
    QueryRouter.expire_stale(0)
    :ok
  end

  describe "query message handling" do
    test "agent receives query and appends to message history" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      # Send a query to this agent via PubSub (simulating QueryRouter delivery)
      Comms.send_to(team_id, name, {:query, "q-123", "researcher", "Where is config?", []})

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.role == :user
      assert msg.content =~ "[Query from researcher | ID: q-123]"
      assert msg.content =~ "Where is config?"
      assert msg.content =~ "peer_answer_question"
      assert msg.content =~ "q-123"
    end

    test "agent filters self-messages from broadcast" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      # Send a query with from == agent name (self-broadcast)
      Comms.send_to(team_id, name, {:query, "q-self", to_string(name), "My own question", []})

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert history == []
    end

    test "agent includes enrichments in query message" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      enrichments = [
        "[Context Keeper]: We use JWT for auth",
        "[Context Keeper]: RS256 signing"
      ]

      Comms.send_to(
        team_id,
        name,
        {:query, "q-enriched", "lead", "What auth format?", enrichments}
      )

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.content =~ "Relevant context:"
      assert msg.content =~ "JWT"
      assert msg.content =~ "RS256"
    end
  end

  describe "query answer handling" do
    test "agent receives answer and appends to history" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      Comms.send_to(
        team_id,
        name,
        {:query_answer, "q-456", "coder", "The answer is 42", []}
      )

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.role == :user
      assert msg.content =~ "[Answer from coder | Query: q-456]"
      assert msg.content =~ "The answer is 42"
    end

    test "answer includes enrichments from routing" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      enrichments = ["bob's note: check lib/auth.ex", "carol's note: uses JWT"]

      Comms.send_to(
        team_id,
        name,
        {:query_answer, "q-789", "dave", "Bearer token format", enrichments}
      )

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.content =~ "Enrichments gathered during routing:"
      assert msg.content =~ "lib/auth.ex"
      assert msg.content =~ "JWT"
    end
  end

  describe "query messages via team broadcast" do
    test "query via team broadcast reaches agent" do
      team_id = unique_team_id()
      %{pid: pid} = start_agent(team_id: team_id, name: "receiver")

      # Broadcast to team (not directly to agent)
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}",
        {:query, "q-broadcast", "sender", "Team-wide question?", []}
      )

      Process.sleep(50)

      history = Agent.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.content =~ "[Query from sender"
      assert msg.content =~ "Team-wide question?"
    end
  end

  describe "multiple messages accumulate" do
    test "queries and answers accumulate in order" do
      %{pid: pid, team_id: team_id, name: name} = start_agent()

      Comms.send_to(team_id, name, {:query, "q-1", "lead", "First question?", []})
      Process.sleep(20)

      Comms.send_to(team_id, name, {:query_answer, "q-0", "peer", "Answer to earlier Q", []})
      Process.sleep(20)

      Comms.send_to(team_id, name, {:query, "q-2", "tester", "Second question?", []})
      Process.sleep(20)

      history = Agent.get_history(pid)
      assert length(history) == 3

      assert Enum.at(history, 0).content =~ "First question?"
      assert Enum.at(history, 1).content =~ "Answer to earlier Q"
      assert Enum.at(history, 2).content =~ "Second question?"
    end
  end
end
