defmodule Loomkin.Tools.PeerAskQuestionTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Comms, Manager, QueryRouter}
  alias Loomkin.Tools.PeerAskQuestion

  setup do
    {:ok, team_id} = Manager.create_team(name: "ask-q-tool-test")

    QueryRouter.expire_stale(0)
    Process.sleep(1)
    QueryRouter.expire_stale(0)

    on_exit(fn ->
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp context(name \\ "alice"), do: %{agent_name: name, team_id: "irrelevant"}

  describe "run/2" do
    test "sends targeted question and returns query_id", %{team_id: team_id} do
      Comms.subscribe(team_id, "bob")

      params = %{team_id: team_id, question: "How does auth work?", target: "bob"}
      assert {:ok, %{result: result, query_id: query_id}} = PeerAskQuestion.run(params, context())

      assert result =~ "Question sent to bob"
      assert result =~ query_id
      assert is_binary(query_id)

      assert_receive {:query, ^query_id, "alice", "How does auth work?", _enrichments}
    end

    test "broadcasts question when no target specified", %{team_id: team_id} do
      Comms.subscribe(team_id, "alice")

      params = %{team_id: team_id, question: "Anyone know about config?"}
      assert {:ok, %{result: result}} = PeerAskQuestion.run(params, context())

      assert result =~ "all agents"
      assert_receive {:query, _query_id, "alice", "Anyone know about config?", _}
    end

    test "includes extra context in question", %{team_id: team_id} do
      Comms.subscribe(team_id, "bob")

      params = %{
        team_id: team_id,
        question: "What pattern for auth?",
        target: "bob",
        context: "I saw JWT mentioned in lib/auth.ex"
      }

      assert {:ok, _} = PeerAskQuestion.run(params, context())

      assert_receive {:query, _query_id, "alice", question, _}
      assert question =~ "What pattern for auth?"
      assert question =~ "Context from alice: I saw JWT mentioned"
    end

    test "works with string keys", %{team_id: team_id} do
      Comms.subscribe(team_id, "bob")

      params = %{"team_id" => team_id, "question" => "String key test?", "target" => "bob"}
      assert {:ok, %{result: result}} = PeerAskQuestion.run(params, context())

      assert result =~ "Question sent to bob"
    end
  end
end
