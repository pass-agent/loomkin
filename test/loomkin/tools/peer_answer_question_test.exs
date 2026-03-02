defmodule Loomkin.Tools.PeerAnswerQuestionTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Comms, Manager, QueryRouter}
  alias Loomkin.Tools.PeerAnswerQuestion

  setup do
    {:ok, team_id} = Manager.create_team(name: "answer-q-tool-test")

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

  defp context(name \\ "bob"), do: %{agent_name: name, team_id: "irrelevant"}

  describe "run/2" do
    test "delivers answer back to origin agent", %{team_id: team_id} do
      Comms.subscribe(team_id, "alice")

      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Question?", target: "bob")

      params = %{team_id: team_id, query_id: query_id, answer: "The answer is 42"}
      assert {:ok, %{result: result}} = PeerAnswerQuestion.run(params, context())
      assert result =~ "Answer delivered"
      assert result =~ query_id

      assert_receive {:query_answer, ^query_id, "bob", "The answer is 42", _}
    end

    test "returns friendly message for unknown query", %{team_id: team_id} do
      params = %{team_id: team_id, query_id: Ecto.UUID.generate(), answer: "Too late"}
      assert {:ok, %{result: result}} = PeerAnswerQuestion.run(params, context())
      assert result =~ "not found"
      assert result =~ "expired"
    end

    test "works with string keys", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Q?", target: "bob")

      params = %{"team_id" => team_id, "query_id" => query_id, "answer" => "String key answer"}
      assert {:ok, %{result: result}} = PeerAnswerQuestion.run(params, context())
      assert result =~ "Answer delivered"
    end
  end
end
