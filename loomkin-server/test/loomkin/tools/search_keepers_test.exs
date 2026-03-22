defmodule Loomkin.Tools.SearchKeepersTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ContextKeeper, Manager}
  alias Loomkin.Tools.SearchKeepers

  setup do
    {:ok, team_id} = Manager.create_team(name: "search-keepers-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp spawn_keeper(team_id, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loomkin.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id,
         team_id: team_id,
         topic: Keyword.get(opts, :topic, "test topic"),
         source_agent: Keyword.get(opts, :source_agent, "test-agent"),
         messages: Keyword.get(opts, :messages, [])}
      )

    %{pid: pid, id: id}
  end

  defp context(team_id), do: %{agent_name: "tester", team_id: team_id}

  describe "run/2" do
    test "returns no-match message when no keepers exist", %{team_id: team_id} do
      params = %{query: "authentication", team_id: team_id}
      assert {:ok, %{result: result}} = SearchKeepers.run(params, context(team_id))
      assert result == "No keepers found matching the query."
    end

    test "returns ranked keepers with relevance scores", %{team_id: team_id} do
      %{id: id1} =
        spawn_keeper(team_id,
          topic: "auth implementation details",
          source_agent: "researcher"
        )

      %{id: id2} =
        spawn_keeper(team_id,
          topic: "database schema design",
          source_agent: "coder"
        )

      params = %{query: "auth implementation", team_id: team_id}
      assert {:ok, %{result: result}} = SearchKeepers.run(params, context(team_id))

      assert result =~ "Found 2 keeper(s)"
      assert result =~ "Keeper:#{id1}"
      assert result =~ "Keeper:#{id2}"
      assert result =~ ~s(topic="auth implementation details")
      assert result =~ "source=researcher"
    end

    test "keepers with zero relevance are still listed", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "database schema design",
        source_agent: "coder"
      )

      params = %{query: "authentication", team_id: team_id}
      assert {:ok, %{result: result}} = SearchKeepers.run(params, context(team_id))

      assert result =~ "Found 1 keeper(s)"
      assert result =~ "relevance=0"
    end

    test "results are sorted by relevance descending", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "database schema design",
        source_agent: "coder"
      )

      spawn_keeper(team_id,
        topic: "auth database implementation",
        source_agent: "researcher"
      )

      params = %{query: "database implementation", team_id: team_id}
      assert {:ok, %{result: result}} = SearchKeepers.run(params, context(team_id))

      # The keeper with "auth database implementation" in its topic should appear first (relevance=2)
      lines =
        result |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "- "))

      [first_entry, second_entry] = lines
      assert first_entry =~ "relevance=2"
      assert second_entry =~ "relevance=1"
    end
  end
end
