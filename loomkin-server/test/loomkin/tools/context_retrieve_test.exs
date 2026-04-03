defmodule Loomkin.Tools.ContextRetrieveTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ContextKeeper, Manager}
  alias Loomkin.Tools.ContextRetrieve

  setup do
    {:ok, team_id} = Manager.create_team(name: "ctx-retrieve-tool-test")

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

  defp context, do: %{agent_name: "tester", team_id: "irrelevant"}

  describe "run/2" do
    test "retrieves raw messages from best matching keeper", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "auth implementation",
        messages: [%{role: :user, content: "We use JWT tokens"}]
      )

      params = %{team_id: team_id, query: "auth implementation"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "JWT tokens"
    end

    test "retrieves from specific keeper by id", %{team_id: team_id} do
      %{id: id} =
        spawn_keeper(team_id,
          topic: "database design",
          messages: [%{role: :user, content: "PostgreSQL with binary_id"}]
        )

      params = %{team_id: team_id, query: "database", keeper_id: id}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "PostgreSQL"
    end

    test "returns friendly message when no context found", %{team_id: team_id} do
      params = %{team_id: team_id, query: "nonexistent topic"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "No relevant context found"
    end

    test "truncates result at 8000 chars", %{team_id: team_id} do
      long_content = String.duplicate("x", 10_000)

      spawn_keeper(team_id,
        topic: "long topic",
        messages: [%{role: :user, content: long_content}]
      )

      params = %{team_id: team_id, query: "long topic"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert String.length(result) <= 8000
      assert String.ends_with?(result, "...")
    end

    test "explicit raw mode returns formatted messages", %{team_id: team_id} do
      %{id: id} =
        spawn_keeper(team_id,
          topic: "raw test",
          messages: [
            %{role: :user, content: "question about raw"},
            %{role: :assistant, content: "answer about raw"}
          ]
        )

      params = %{team_id: team_id, query: "raw test", keeper_id: id, mode: "raw"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "[user]: question about raw"
      assert result =~ "[assistant]: answer about raw"
    end

    @tag :llm_dependent
    test "smart mode returns binary result", %{team_id: team_id} do
      %{id: id} =
        spawn_keeper(team_id,
          topic: "smart test",
          messages: [%{role: :user, content: "smart content here"}]
        )

      params = %{
        team_id: team_id,
        query: "what is the smart content?",
        keeper_id: id,
        mode: "smart"
      }

      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert is_binary(result)
    end

    test "works with string keys", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "string keys test",
        messages: [%{role: :user, content: "string key content"}]
      )

      params = %{"team_id" => team_id, "query" => "string keys test"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "string key content"
    end

    test "synthesize mode returns combined answer from multiple keepers", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "auth implementation",
        source_agent: "researcher",
        messages: [%{role: :user, content: "We use JWT tokens for auth"}]
      )

      spawn_keeper(team_id,
        topic: "auth testing",
        source_agent: "tester",
        messages: [%{role: :user, content: "Auth tests cover login and logout"}]
      )

      params = %{team_id: team_id, query: "auth", mode: "synthesize"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "synthesize mode returns not-found message when no keepers match", %{team_id: team_id} do
      params = %{team_id: team_id, query: "nonexistent", mode: "synthesize"}
      assert {:ok, %{result: result}} = ContextRetrieve.run(params, context())
      assert result =~ "No relevant context found"
    end
  end
end
