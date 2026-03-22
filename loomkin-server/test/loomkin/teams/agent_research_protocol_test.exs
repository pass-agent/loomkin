defmodule Loomkin.Teams.AgentResearchProtocolTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent

  setup do
    # Checkout the DB connection and share it so the agent GenServer can use it
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Loomkin.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Loomkin.Repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: start a bare agent process for handle_call / :sys.get_state testing.
  # Mirrors the pattern in agent_spawn_gate_test.exs.
  # ---------------------------------------------------------------------------

  defp unique_team_id, do: "test-team-#{System.unique_integer([:positive])}"
  defp unique_name, do: "agent-#{System.unique_integer([:positive])}"

  defp start_agent(opts \\ []) do
    team_id = Keyword.get(opts, :team_id, unique_team_id())
    name = Keyword.get(opts, :name, unique_name())

    {:ok, pid} =
      start_supervised(
        {Agent,
         [
           team_id: team_id,
           name: name,
           role: :lead,
           model: "claude-3-haiku-20240307"
         ]},
        id: {team_id, name}
      )

    {pid, team_id, name}
  end

  # ---------------------------------------------------------------------------
  # 1. spawn_type: :research auto-approve path
  # ---------------------------------------------------------------------------

  describe "spawn_type: :research auto-approve path" do
    test "check_spawn_budget returns :ok for a small research spawn within budget" do
      {pid, _team_id, _name} = start_agent()
      # A small estimated cost (0.20) should pass for a fresh agent with 5.0 budget
      assert GenServer.call(pid, {:check_spawn_budget, 0.20}) == :ok
    end

    test "agent spawn settings do not auto_approve_spawns by default (research path bypasses this)" do
      {pid, _team_id, _name} = start_agent()
      %{auto_approve_spawns: auto_approve} = GenServer.call(pid, :get_spawn_settings)
      # research path is independent of auto_approve_spawns setting
      assert auto_approve == false
    end

    test "enter_awaiting_synthesis cast transitions agent to :awaiting_synthesis (research auto-approve path effect)" do
      {pid, _team_id, _name} = start_agent()
      # The run_research_spawn/6 function casts {:enter_awaiting_synthesis, count}
      # We test the cast handler directly here to verify the research path's core side-effect
      GenServer.cast(pid, {:enter_awaiting_synthesis, 2})
      # Allow cast to process
      :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :awaiting_synthesis
    end
  end

  # ---------------------------------------------------------------------------
  # 2. budget check still runs for research spawns
  # ---------------------------------------------------------------------------

  describe "budget check still runs for research spawns" do
    test "research spawn exceeding remaining budget returns {:budget_exceeded, _} from check_spawn_budget" do
      {pid, _team_id, _name} = start_agent()
      # Default budget is 5.0; 999.0 exceeds it
      result = GenServer.call(pid, {:check_spawn_budget, 999.0})
      assert {:budget_exceeded, %{remaining: _remaining, estimated: 999.0}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # 3. :awaiting_synthesis status transition
  # ---------------------------------------------------------------------------

  describe ":awaiting_synthesis status transition" do
    test "agent transitions to :awaiting_synthesis after {:enter_awaiting_synthesis, n} cast" do
      {pid, _team_id, _name} = start_agent()
      GenServer.cast(pid, {:enter_awaiting_synthesis, 2})
      :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :awaiting_synthesis
    end

    test "agent transitions back to :working after :exit_awaiting_synthesis cast" do
      {pid, _team_id, _name} = start_agent()
      GenServer.cast(pid, {:enter_awaiting_synthesis, 2})
      :sys.get_state(pid)
      GenServer.cast(pid, :exit_awaiting_synthesis)
      :sys.get_state(pid)
      state = :sys.get_state(pid)
      assert state.status == :working
    end

    test "handle_cast(:request_pause) queues pause rather than immediately pausing when status is :awaiting_synthesis" do
      {pid, _team_id, _name} = start_agent()
      GenServer.cast(pid, {:enter_awaiting_synthesis, 2})
      :sys.get_state(pid)
      GenServer.cast(pid, :request_pause)
      :sys.get_state(pid)
      state = :sys.get_state(pid)
      # Status should remain :awaiting_synthesis (not :paused)
      assert state.status == :awaiting_synthesis
      # pause_queued should be true
      assert state.pause_queued == true
    end
  end

  # ---------------------------------------------------------------------------
  # 4. peer_message routing to tool task during :awaiting_synthesis
  # ---------------------------------------------------------------------------

  describe "peer_message routing to tool task during :awaiting_synthesis" do
    test "incoming peer_message cast is forwarded to registered tool task pid when agent is :awaiting_synthesis" do
      {pid, team_id, agent_name} = start_agent()

      # Enter awaiting_synthesis
      GenServer.cast(pid, {:enter_awaiting_synthesis, 1})
      :sys.get_state(pid)

      # Register the test process as the "tool task" in the Registry
      Registry.register(
        Loomkin.Teams.AgentRegistry,
        {:awaiting_synthesis, team_id, agent_name},
        self()
      )

      # Send a peer_message while agent is :awaiting_synthesis
      GenServer.cast(pid, {:peer_message, "researcher-1", "Found relevant data"})
      :sys.get_state(pid)

      # The test process (registered as tool task) should receive {:research_findings, from, content}
      assert_receive {:research_findings, "researcher-1", "Found relevant data"}, 1000
    end

    test "peer_message is not appended to messages list when agent is :awaiting_synthesis" do
      {pid, team_id, agent_name} = start_agent()

      state_before = :sys.get_state(pid)
      initial_message_count = length(state_before.messages)

      # Enter awaiting_synthesis
      GenServer.cast(pid, {:enter_awaiting_synthesis, 1})
      :sys.get_state(pid)

      # Register test process as tool task
      Registry.register(
        Loomkin.Teams.AgentRegistry,
        {:awaiting_synthesis, team_id, agent_name},
        self()
      )

      # Send peer_message
      GenServer.cast(pid, {:peer_message, "researcher-1", "Some findings"})
      :sys.get_state(pid)

      state_after = :sys.get_state(pid)
      # Messages list should not grow (message was routed to tool task, not appended)
      assert length(state_after.messages) == initial_message_count
    end
  end
end
