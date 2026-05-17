defmodule Loomkin.Orchestration.Pipelines.LitePipelineTest do
  @moduledoc """
  Unit tests for the real `LitePipeline` implementation.

  We don't spin up a full `Loomkin.Teams.Agent` here — that GenServer pulls
  in the entire AgentLoop / model router stack and is expensive to boot.
  Instead we register a tiny stub GenServer under the same
  `Loomkin.Teams.AgentRegistry` key the real agent would use; `Teams.Agent`'s
  public API (`send_message/2`) is just `GenServer.call(pid, {:send_message,
  text}, :infinity)`, so the stub answering that call is indistinguishable
  from a real agent for the purposes of this pipeline's contract.
  """

  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Pipelines.LitePipeline

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
    # Each test uses a unique team_id so the Registry key doesn't collide
    # with other async-false tests sharing the registry.
    team_id = "team-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, team_id: team_id}
  end

  describe "run/3 — happy path" do
    test "routes to the team's concierge and returns its response", %{team_id: team_id} do
      {:ok, _pid} =
        StubAgent.start_link(team_id: team_id, name: "concierge", reply: {:ok, "hello back"})

      state = %{id: "sess-A", team_id: team_id, workspace_id: nil}

      assert {:ok, "hello back"} = LitePipeline.run(state, "hello")
    end

    test "honors a custom :target_agent from opts", %{team_id: team_id} do
      {:ok, _} =
        StubAgent.start_link(team_id: team_id, name: "executor", reply: {:ok, "did the thing"})

      state = %{id: "sess-B", team_id: team_id, workspace_id: nil}

      assert {:ok, "did the thing"} =
               LitePipeline.run(state, "do the thing", target_agent: "executor")
    end
  end

  describe "run/3 — error paths" do
    test "returns {:error, :no_team} when session has no team_id" do
      state = %{id: "sess-C", team_id: nil, workspace_id: nil}

      assert {:error, :no_team} = LitePipeline.run(state, "hi")
    end

    test "returns {:error, :no_team} when team_id key is missing entirely" do
      assert {:error, :no_team} = LitePipeline.run(%{id: "sess-D"}, "hi")
    end

    test "returns {:error, {:agent_not_found, _}} when the concierge isn't registered",
         %{team_id: team_id} do
      state = %{id: "sess-E", team_id: team_id, workspace_id: nil}

      assert {:error, {:agent_not_found, "concierge"}} = LitePipeline.run(state, "hi")
    end

    test "propagates an agent's {:error, reason} reply", %{team_id: team_id} do
      {:ok, _} =
        StubAgent.start_link(team_id: team_id, name: "concierge", reply: {:error, :boom})

      state = %{id: "sess-F", team_id: team_id, workspace_id: nil}

      assert {:error, :boom} = LitePipeline.run(state, "hi")
    end

    test "wraps unexpected agent replies in {:error, {:unexpected_reply, _}}",
         %{team_id: team_id} do
      {:ok, _} = StubAgent.start_link(team_id: team_id, name: "concierge", reply: :weird)

      state = %{id: "sess-G", team_id: team_id, workspace_id: nil}

      assert {:error, {:unexpected_reply, :weird}} = LitePipeline.run(state, "hi")
    end
  end
end
