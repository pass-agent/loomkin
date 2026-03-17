defmodule Loomkin.Tools.IntrospectFailurePatternsTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.ContextKeeper
  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.IntrospectFailurePatterns

  setup do
    {:ok, team_id} = Manager.create_team(name: "failure-patterns-test")

    on_exit(fn ->
      if Process.whereis(Loomkin.Teams.AgentSupervisor) do
        DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
        |> Enum.each(fn {_, pid, _, _} ->
          DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
        end)
      end

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp spawn_failure_keeper(team_id, agent_name, opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    messages =
      Keyword.get(opts, :messages, [
        %{
          role: :system,
          content:
            "Failure record: tool=shell category=compile_error severity=medium\nError: compilation failed"
        }
      ])

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loomkin.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id,
         team_id: team_id,
         topic: "failures:#{agent_name}",
         source_agent: to_string(agent_name),
         messages: messages,
         metadata: %{"type" => "failure_memory"}}
      )

    %{pid: pid, id: id}
  end

  defp context(team_id, agent_name \\ "test-agent") do
    %{team_id: team_id, agent_name: agent_name}
  end

  describe "run/2" do
    test "returns no-match message when no failure keepers exist", %{team_id: team_id} do
      params = %{team_id: team_id}

      assert {:ok, %{result: result}} =
               IntrospectFailurePatterns.run(params, context(team_id))

      assert result =~ "No failure patterns found"
    end

    test "finds failure memory keepers and returns report", %{team_id: team_id} do
      spawn_failure_keeper(team_id, "test-agent")

      params = %{team_id: team_id}

      assert {:ok, %{result: result}} =
               IntrospectFailurePatterns.run(params, context(team_id))

      # Should either have a synthesized report or a keeper list
      assert result =~ "failure" or result =~ "Failure"
    end

    test "filters to failure keepers only (ignores regular keepers)", %{team_id: team_id} do
      # Spawn a regular keeper
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Loomkin.Teams.AgentSupervisor,
          {ContextKeeper,
           id: Ecto.UUID.generate(),
           team_id: team_id,
           topic: "code review notes",
           source_agent: "test-agent",
           messages: [%{role: :user, content: "some notes"}]}
        )

      params = %{team_id: team_id}

      assert {:ok, %{result: result}} =
               IntrospectFailurePatterns.run(params, context(team_id))

      # No failure keepers, so should report none found
      assert result =~ "No failure patterns found"
    end

    test "uses optional query to focus results", %{team_id: team_id} do
      spawn_failure_keeper(team_id, "test-agent",
        messages: [
          %{role: :system, content: "Failure: compile_error in shell tool"}
        ]
      )

      params = %{team_id: team_id, query: "compile errors"}

      assert {:ok, %{result: result}} =
               IntrospectFailurePatterns.run(params, context(team_id))

      assert result =~ "failure" or result =~ "Failure"
    end
  end
end
