defmodule Loomkin.Orchestration.Pipelines.ShortPipelineTest do
  @moduledoc """
  ShortPipeline currently delegates to LitePipeline. These tests pin that
  contract so a future divergence is caught explicitly rather than silently.
  """

  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Pipelines.ShortPipeline

  defmodule StubAgent do
    use GenServer

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      name = Keyword.fetch!(opts, :name)
      reply = Keyword.get(opts, :reply, {:ok, "ack"})

      GenServer.start_link(__MODULE__, reply,
        name: {:via, Registry, {Loomkin.Teams.AgentRegistry, {team_id, name}}}
      )
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call({:send_message, _text}, _from, reply) do
      {:reply, reply, reply}
    end
  end

  setup do
    team_id = "team-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, team_id: team_id}
  end

  test "returns {:error, :no_team} when session has no team" do
    assert {:error, :no_team} =
             ShortPipeline.run(%{id: "sess-1", team_id: nil, workspace_id: nil}, "run the tests")
  end

  test "routes to the concierge and returns its response", %{team_id: team_id} do
    {:ok, _} =
      StubAgent.start_link(team_id: team_id, name: "concierge", reply: {:ok, "tests passed"})

    state = %{id: "sess-2", team_id: team_id, workspace_id: nil}

    assert {:ok, "tests passed"} = ShortPipeline.run(state, "run the tests")
  end

  test "honors :target_agent for deterministic tool routing", %{team_id: team_id} do
    {:ok, _} =
      StubAgent.start_link(team_id: team_id, name: "executor", reply: {:ok, "diff shown"})

    state = %{id: "sess-3", team_id: team_id, workspace_id: nil}

    assert {:ok, "diff shown"} =
             ShortPipeline.run(state, "show the diff", target_agent: "executor")
  end
end
