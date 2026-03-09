defmodule Loomkin.Teams.AgentWeaverTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Capabilities
  alias Loomkin.Teams.Manager

  defp unique_team_id do
    "test-weaver-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(overrides) do
    team_id = Keyword.get(overrides, :team_id, unique_team_id())
    name = Keyword.get(overrides, :name, "agent-#{:erlang.unique_integer([:positive])}")
    role = Keyword.get(overrides, :role, :coder)

    opts =
      [team_id: team_id, name: name, role: role]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Agent, opts}, id: {team_id, name})
    %{pid: pid, team_id: team_id, name: name, role: role}
  end

  # Start a weaver agent but immediately replace its state to prevent
  # the real auto_weave loop from running (which would call LLM and DB).
  # Returns the agent in idle state with loop_task: nil.
  defp start_weaver_idle(team_id, name \\ "weaver") do
    agent = start_agent(team_id: team_id, name: name, role: :weaver)

    # The weaver's handle_continue(:auto_weave) fires and starts a loop task.
    # Wait for it to start, then cancel it and reset to idle.
    Process.sleep(100)

    :sys.replace_state(agent.pid, fn state ->
      # Kill the real loop task if one exists
      case state.loop_task do
        {%Task{pid: task_pid}, _from} ->
          Process.exit(task_pid, :kill)

        _ ->
          :ok
      end

      %{state | loop_task: nil, status: :idle, task: nil, failure_count: 0}
    end)

    agent
  end

  defp make_fake_loop_task(pid) do
    ref = make_ref()
    fake_task = %Task{pid: pid, ref: ref, owner: pid, mfa: {__MODULE__, :fake, []}}
    {fake_task, ref}
  end

  describe "weaver auto-start" do
    test "weaver triggers handle_continue(:auto_weave) on init" do
      team_id = unique_team_id()

      # Start a coder so the team is "active"
      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)

      # Start the weaver — it auto-starts via handle_continue(:auto_weave)
      weaver = start_agent(team_id: team_id, name: "weaver", role: :weaver)

      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      # Weaver should have started a loop task and be in :working status
      assert state.loop_task != nil
      assert state.status == :working
      assert state.task != nil
      assert state.task[:title] == "coordination cycle"
    end

    test "weaver re-triggers after loop completion if team is active" do
      team_id = unique_team_id()

      # Start a coder to keep the team active
      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)

      # Start weaver in idle state (suppressed auto_weave)
      weaver = start_weaver_idle(team_id)

      # Simulate a loop that just completed by setting up a fake task and sending loop_ok
      {fake_task, ref} = make_fake_loop_task(self())

      :sys.replace_state(weaver.pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working, task: nil}
      end)

      # Send fake loop completion (no task_id, so Tasks.complete_task won't be called)
      send(
        weaver.pid,
        {ref,
         {:loop_ok, "cycle done", [%{role: :assistant, content: "cycle done"}], %{usage: %{}}}}
      )

      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      # After completion, weaver should be idle with loop_task cleared
      assert state.status == :idle
      assert state.loop_task == nil

      # Simulate the scheduled :weaver_cycle timer firing
      send(weaver.pid, :weaver_cycle)
      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      # Should have re-entered a loop via handle_continue(:auto_weave)
      assert state.loop_task != nil
      assert state.status == :working
    end

    test "weaver stops cycling when no active agents" do
      team_id = unique_team_id()

      # Start weaver alone (no other agents)
      weaver = start_weaver_idle(team_id)

      # Simulate loop completion
      {fake_task, ref} = make_fake_loop_task(self())

      :sys.replace_state(weaver.pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working, task: nil}
      end)

      send(
        weaver.pid,
        {ref, {:loop_ok, "done", [%{role: :assistant, content: "done"}], %{usage: %{}}}}
      )

      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      # With no other agents active, weaver should be idle and NOT re-trigger
      assert state.status == :idle
      assert state.loop_task == nil

      # Wait long enough for any scheduled :weaver_cycle to fire (adaptive delay is 0 or 30s,
      # but in test with no queued messages it would be 30s — we just need to confirm the
      # agent stays idle, meaning no cycle was scheduled)
      Process.sleep(300)

      state = :sys.get_state(weaver.pid)
      assert state.status == :idle
      assert state.loop_task == nil
    end

    test "weaver re-triggers with backoff after loop error" do
      team_id = unique_team_id()

      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)
      weaver = start_weaver_idle(team_id)

      # Simulate an active loop
      {fake_task, ref} = make_fake_loop_task(self())

      :sys.replace_state(weaver.pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working, task: nil}
      end)

      # Simulate loop error
      send(weaver.pid, {ref, {:loop_error, :timeout, []}})
      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      assert state.status == :idle
      assert state.loop_task == nil
      assert state.failure_count == 1

      # Manually trigger the scheduled cycle
      send(weaver.pid, :weaver_cycle)
      Process.sleep(200)

      state = :sys.get_state(weaver.pid)
      # Should have re-entered a loop
      assert state.loop_task != nil
      assert state.status == :working
    end

    test "weaver stops retrying after 3 consecutive errors" do
      team_id = unique_team_id()

      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)
      weaver = start_weaver_idle(team_id)

      # Simulate 4 consecutive loop errors
      for _i <- 1..4 do
        state = :sys.get_state(weaver.pid)

        if state.loop_task == nil do
          # Set up a fake loop task
          {fake_task, ref} = make_fake_loop_task(self())

          :sys.replace_state(weaver.pid, fn s ->
            %{s | loop_task: {fake_task, nil}, status: :working, task: nil}
          end)

          send(weaver.pid, {ref, {:loop_error, :timeout, []}})
          Process.sleep(100)
        else
          {%Task{ref: ref}, _from} = state.loop_task
          send(weaver.pid, {ref, {:loop_error, :timeout, []}})
          Process.sleep(100)
        end
      end

      state = :sys.get_state(weaver.pid)
      # After 4 errors, failure_count should be 4 (past the 3-retry cap)
      assert state.failure_count == 4
      assert state.loop_task == nil
      assert state.status == :idle
    end

    test "weaver receives peer messages while in cycle" do
      team_id = unique_team_id()

      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)
      weaver = start_weaver_idle(team_id)

      # Set up a fake active loop
      {fake_task, _ref} = make_fake_loop_task(self())

      :sys.replace_state(weaver.pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working, messages: []}
      end)

      # Send a peer message while the loop is active
      Agent.peer_message(weaver.pid, "coder-1", "I found a bug in auth.ex")
      Process.sleep(100)

      state = :sys.get_state(weaver.pid)
      # peer_message appends directly to state.messages (not dropped)
      assert Enum.any?(state.messages, fn msg ->
               String.contains?(msg.content, "I found a bug in auth.ex")
             end)
    end

    test "weaver_cycle message is ignored when loop is already active" do
      team_id = unique_team_id()

      _coder = start_agent(team_id: team_id, name: "coder-1", role: :coder)
      weaver = start_weaver_idle(team_id)

      # Set up a fake active loop
      {fake_task, _ref} = make_fake_loop_task(self())

      :sys.replace_state(weaver.pid, fn state ->
        %{state | loop_task: {fake_task, nil}, status: :working}
      end)

      # Send weaver_cycle while loop is active — should be a no-op
      send(weaver.pid, :weaver_cycle)
      Process.sleep(100)

      state = :sys.get_state(weaver.pid)
      assert state.loop_task != nil
    end
  end

  describe "weaver bootstrap" do
    test "bootstrap spawns concierge, orienter, and weaver" do
      team_id = unique_team_id()

      # Manually spawn the 3 bootstrap agents as session.ex does
      {:ok, _} = Manager.create_team(name: team_id, team_id: team_id)

      Manager.spawn_agent(team_id, "concierge", :concierge, [])
      Manager.spawn_agent(team_id, "orienter", :orienter, [])
      Manager.spawn_agent(team_id, "weaver", :weaver, [])

      Process.sleep(200)

      agents = Manager.list_agents(team_id)
      agent_names = Enum.map(agents, fn %{name: name} -> name end)

      assert "concierge" in agent_names
      assert "orienter" in agent_names
      assert "weaver" in agent_names
      assert length(agent_names) >= 3

      on_exit(fn ->
        Loomkin.Teams.TableRegistry.delete_table(team_id)
      end)
    end
  end

  describe "weaver integration guards" do
    test "weaver excluded from rebalancer stuck checks" do
      Application.put_env(:loomkin, :start_nervous_system, false)

      {:ok, team_id} = Manager.create_team(name: "rebalancer-weaver-test")

      {:ok, pid} =
        start_supervised(
          {Loomkin.Teams.Rebalancer, team_id: team_id, check_interval: 100_000},
          id: {:rebalancer, team_id}
        )

      # Simulate weaver and coder both stuck (working for 6 min, no activity)
      old_time = System.monotonic_time(:millisecond) - 6 * 60_000

      :sys.replace_state(pid, fn state ->
        %{
          state
          | working_since: %{"weaver" => old_time, "coder-1" => old_time},
            last_activity: %{"weaver" => old_time, "coder-1" => old_time}
        }
      end)

      # Trigger stuck check
      send(pid, :check_stuck)
      Process.sleep(100)

      state = :sys.get_state(pid)
      # Weaver should NOT be nudged
      refute Map.has_key?(state.nudge_counts, "weaver")
      # Coder should be nudged
      assert Map.get(state.nudge_counts, "coder-1") == 1

      on_exit(fn ->
        Application.put_env(:loomkin, :start_nervous_system, true)
        Loomkin.Teams.TableRegistry.delete_table(team_id)
      end)
    end

    test "weaver excluded from best_agent_for/2 capability ranking" do
      {:ok, team_id} = Manager.create_team(name: "cap-weaver-test")

      # Record capabilities for both weaver and coder
      Capabilities.record_completion(team_id, "weaver", :coding, :success)
      Capabilities.record_completion(team_id, "weaver", :coding, :success)
      Capabilities.record_completion(team_id, "coder-1", :coding, :success)

      ranked = Capabilities.best_agent_for(team_id, :coding)

      agent_names = Enum.map(ranked, & &1.agent)
      refute "weaver" in agent_names
      assert "coder-1" in agent_names

      on_exit(fn ->
        Loomkin.Teams.TableRegistry.delete_table(team_id)
      end)
    end
  end
end
