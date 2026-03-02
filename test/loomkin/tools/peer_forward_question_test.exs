defmodule Loomkin.Tools.PeerForwardQuestionTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Comms, Manager, QueryRouter}
  alias Loomkin.Tools.PeerForwardQuestion

  setup do
    {:ok, team_id} = Manager.create_team(name: "fwd-q-tool-test")

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
    test "forwards question to target with enrichment", %{team_id: team_id} do
      Comms.subscribe(team_id, "carol")

      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Complex Q?", target: "bob")

      params = %{
        team_id: team_id,
        query_id: query_id,
        target: "carol",
        enrichment: "I checked lib/foo.ex, relevant code is there"
      }

      assert {:ok, %{result: result}} = PeerForwardQuestion.run(params, context())
      assert result =~ "forwarded to carol"

      assert_receive {:query, ^query_id, "bob", "Complex Q?", enrichments}
      assert Enum.any?(enrichments, &(&1 =~ "lib/foo.ex"))
    end

    test "returns friendly message when max hops reached", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Bouncy?", target: "bob", max_hops: 1)

      # Use up the single allowed hop
      :ok = QueryRouter.forward(query_id, "bob", "carol", "hop1")

      # Second forward should fail
      params = %{
        team_id: team_id,
        query_id: query_id,
        target: "dave",
        enrichment: "another hop"
      }

      assert {:ok, %{result: result}} = PeerForwardQuestion.run(params, context("carol"))
      assert result =~ "Maximum forwarding hops reached"
    end

    test "returns friendly message for unknown query", %{team_id: team_id} do
      params = %{
        team_id: team_id,
        query_id: Ecto.UUID.generate(),
        target: "carol",
        enrichment: "some context"
      }

      assert {:ok, %{result: result}} = PeerForwardQuestion.run(params, context())
      assert result =~ "not found"
    end

    test "works with string keys", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Q?", target: "bob")

      params = %{
        "team_id" => team_id,
        "query_id" => query_id,
        "target" => "carol",
        "enrichment" => "string key enrichment"
      }

      assert {:ok, %{result: result}} = PeerForwardQuestion.run(params, context())
      assert result =~ "forwarded to carol"
    end
  end
end
