defmodule Loomkin.Teams.OrchestrationTest do
  @moduledoc """
  End-to-end integration test for Epic 5.10: Team Orchestration & Visibility.

  Exercises the full lifecycle:
    User sends message → Architect spawns team → Agents receive work →
    Execute tools → Complete tasks → Results bubble back to session.

  LLM calls are bypassed by driving the orchestration plumbing directly.
  """

  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Agent, Comms, Tasks}
  alias Loomkin.Teams.Manager, as: TeamManager
  alias Loomkin.Session.Manager, as: SessionManager

  @project_path "/tmp/loom-orchestration-test"

  setup do
    File.mkdir_p!(@project_path)

    # Start a session
    session_id = Ecto.UUID.generate()

    {:ok, session_pid} =
      SessionManager.start_session(
        session_id: session_id,
        model: "test:model",
        project_path: @project_path
      )

    # Subscribe to session events
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "session:#{session_id}")

    on_exit(fn ->
      File.rm_rf!(@project_path)
    end)

    %{session_id: session_id, session_pid: session_pid}
  end

  describe "full orchestration lifecycle" do
    test "spawn → assign → execute → complete → report", %{
      session_id: session_id,
      session_pid: session_pid
    } do
      # --- Phase 1: Create backing team and sub-team ---
      # Simulate what the Architect does when it calls team_spawn

      {:ok, backing_team_id} =
        TeamManager.create_team(name: "backing", project_path: @project_path)

      # Wire the session to know about its backing team
      send(session_pid, {:team_created, backing_team_id})
      Process.sleep(50)
      assert_receive {:team_available, ^session_id, ^backing_team_id}

      # Architect spawns a child team (sub-team of the backing team)
      {:ok, sub_team_id} =
        TeamManager.create_sub_team(backing_team_id, "architect",
          name: "code-task",
          project_path: @project_path
        )

      assert sub_team_id in TeamManager.list_sub_teams(backing_team_id)
      assert {:ok, ^backing_team_id} = TeamManager.get_parent_team(sub_team_id)

      # --- Phase 2: Spawn agents in the sub-team ---

      # Subscribe to sub-team PubSub to observe events
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{sub_team_id}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{sub_team_id}:tasks")

      {:ok, lead_pid} =
        TeamManager.spawn_agent(sub_team_id, "lead-1", :lead, project_path: @project_path)

      {:ok, coder_pid} =
        TeamManager.spawn_agent(sub_team_id, "coder-1", :coder, project_path: @project_path)

      {:ok, researcher_pid} =
        TeamManager.spawn_agent(sub_team_id, "researcher-1", :researcher,
          project_path: @project_path
        )

      # Verify agents broadcast their existence on init (5.10.1)
      assert_receive {:agent_status, "lead-1", :idle}
      assert_receive {:agent_status, "coder-1", :idle}
      assert_receive {:agent_status, "researcher-1", :idle}

      # Verify agents are listed
      agents = TeamManager.list_agents(sub_team_id)
      agent_names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert agent_names == ["coder-1", "lead-1", "researcher-1"]

      # --- Phase 3: Create and assign tasks ---
      # This simulates what the lead agent (or Architect) would do after
      # receiving the user's request.

      {:ok, task1} =
        Tasks.create_task(sub_team_id, %{
          title: "Research existing patterns",
          description: "Read lib/ and identify patterns used in the codebase"
        })

      {:ok, task2} =
        Tasks.create_task(sub_team_id, %{
          title: "Implement feature",
          description: "Add the new feature module based on research findings"
        })

      # task2 depends on task1
      {:ok, _dep} = Tasks.add_dependency(task2.id, task1.id, :blocks)

      # Verify task_created events broadcast
      assert_receive {:task_created, _, "Research existing patterns"}
      assert_receive {:task_created, _, "Implement feature"}

      # Assign task1 to researcher
      {:ok, assigned_task1} = Tasks.assign_task(task1.id, "researcher-1")
      assert assigned_task1.status == :assigned
      assert assigned_task1.owner == "researcher-1"

      # Verify task_assigned event
      assert_receive {:task_assigned, task1_id, "researcher-1"}
      assert task1_id == task1.id

      # --- Phase 4: Agent receives task assignment via PubSub ---
      # The task_assigned event is sent to the agent's direct topic.
      # After 5.10.7, agents auto-execute on assignment. For now, we
      # verify the agent receives and stores the task.

      Process.sleep(100)

      researcher_state = :sys.get_state(researcher_pid)
      assert researcher_state.task != nil
      assert researcher_state.task.id == task1.id

      # --- Phase 5: Simulate task execution and completion ---
      # In the full system (5.10.7), the agent would auto-execute via
      # AgentLoop. Here we simulate the completion path.

      {:ok, _} = Tasks.start_task(task1.id)
      assert_receive {:task_started, ^task1_id, "researcher-1"}

      {:ok, completed_task1} =
        Tasks.complete_task(task1.id, "Found 3 patterns: GenServer, PubSub, ETS")

      assert completed_task1.status == :completed
      assert completed_task1.result == "Found 3 patterns: GenServer, PubSub, ETS"

      # Verify task_completed event
      assert_receive {:task_completed, ^task1_id, "researcher-1",
                      "Found 3 patterns: GenServer, PubSub, ETS"}

      # --- Phase 6: Blocked task becomes available ---
      # After task1 completes, task2 should be unblocked

      assert_receive {:tasks_unblocked, unblocked_ids}
      assert task2.id in unblocked_ids

      available = Tasks.list_available(sub_team_id)
      available_ids = Enum.map(available, & &1.id)
      assert task2.id in available_ids

      # Assign and complete task2
      {:ok, _} = Tasks.assign_task(task2.id, "coder-1")
      assert_receive {:task_assigned, task2_id, "coder-1"}
      assert task2_id == task2.id

      {:ok, _} = Tasks.start_task(task2.id)
      {:ok, _} = Tasks.complete_task(task2.id, "Feature implemented in lib/feature.ex")

      assert_receive {:task_completed, ^task2_id, "coder-1",
                      "Feature implemented in lib/feature.ex"}

      # --- Phase 7: Verify all tasks completed ---

      all_tasks = Tasks.list_all(sub_team_id)
      assert Enum.all?(all_tasks, &(&1.status == :completed))

      # --- Phase 8: Team dissolution and cleanup ---
      # When all tasks complete, the sub-team can be dissolved.
      # The parent team's spawning agent receives a notification.

      Phoenix.PubSub.subscribe(
        Loomkin.PubSub,
        "team:#{backing_team_id}:agent:architect"
      )

      TeamManager.dissolve_team(sub_team_id)

      # Spawning agent in parent team receives sub_team_completed
      assert_receive {:sub_team_completed, ^sub_team_id}

      # Sub-team ETS table is cleaned up
      assert {:error, :not_found} = Loomkin.Teams.TableRegistry.get_table(sub_team_id)

      # Sub-team removed from parent's list
      assert sub_team_id not in TeamManager.list_sub_teams(backing_team_id)

      # Agents are stopped
      Process.sleep(50)
      refute Process.alive?(lead_pid)
      refute Process.alive?(coder_pid)
      refute Process.alive?(researcher_pid)

      # Clean up backing team
      TeamManager.dissolve_team(backing_team_id)
    end
  end

  describe "PubSub event ordering" do
    test "events fire in correct sequence during task lifecycle", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "event-order", project_path: @project_path)

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:tasks")

      {:ok, _agent_pid} =
        TeamManager.spawn_agent(team_id, "worker", :coder, project_path: @project_path)

      # Agent init broadcast
      assert_receive {:agent_status, "worker", :idle}

      # Task lifecycle
      {:ok, task} = Tasks.create_task(team_id, %{title: "Ordered task"})
      assert_receive {:task_created, task_id, "Ordered task"}
      assert task_id == task.id

      {:ok, _} = Tasks.assign_task(task.id, "worker")
      assert_receive {:task_assigned, ^task_id, "worker"}

      {:ok, _} = Tasks.start_task(task.id)
      assert_receive {:task_started, ^task_id, "worker"}

      {:ok, _} = Tasks.complete_task(task.id, "done")
      assert_receive {:task_completed, ^task_id, "worker", "done"}

      TeamManager.dissolve_team(team_id)
    end

    test "failed task emits correct event", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "fail-test", project_path: @project_path)

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:tasks")

      {:ok, task} = Tasks.create_task(team_id, %{title: "Doomed task"})
      {:ok, _} = Tasks.assign_task(task.id, "worker")
      {:ok, _} = Tasks.fail_task(task.id, "compilation error")

      assert_receive {:task_failed, _, "worker", "compilation error"}

      TeamManager.dissolve_team(team_id)
    end
  end

  describe "multi-agent coordination" do
    test "multiple agents receive team-wide broadcasts", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "multi-agent", project_path: @project_path)

      {:ok, pid1} =
        TeamManager.spawn_agent(team_id, "agent-a", :coder, project_path: @project_path)

      {:ok, pid2} =
        TeamManager.spawn_agent(team_id, "agent-b", :researcher, project_path: @project_path)

      # Broadcast context update to entire team
      Comms.broadcast(team_id, {:context_update, "lead", %{plan: "build feature X"}})

      Process.sleep(100)

      state1 = :sys.get_state(pid1)
      state2 = :sys.get_state(pid2)

      assert state1.context["lead"] == %{plan: "build feature X"}
      assert state2.context["lead"] == %{plan: "build feature X"}

      TeamManager.dissolve_team(team_id)
    end

    test "peer messages delivered to specific agents", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "peer-msg", project_path: @project_path)

      {:ok, pid1} =
        TeamManager.spawn_agent(team_id, "sender", :lead, project_path: @project_path)

      {:ok, pid2} =
        TeamManager.spawn_agent(team_id, "receiver", :coder, project_path: @project_path)

      Agent.peer_message(pid2, "sender", "Please implement the fix")
      Process.sleep(100)

      history = Agent.get_history(pid2)
      assert length(history) == 1
      assert hd(history).content =~ "sender"
      assert hd(history).content =~ "Please implement the fix"

      # Sender should NOT have the message
      sender_history = Agent.get_history(pid1)
      assert sender_history == []

      TeamManager.dissolve_team(team_id)
    end
  end

  describe "session integration" do
    test "session tracks backing team", %{session_id: session_id, session_pid: session_pid} do
      {:ok, team_id} =
        TeamManager.create_team(name: "session-team", project_path: @project_path)

      send(session_pid, {:team_created, team_id})

      # Wait for the session to process the message and broadcast
      assert_receive {:team_available, ^session_id, ^team_id}, 1000

      # Verify the session stored the team_id (use get_status to flush mailbox first)
      {:ok, :idle} = GenServer.call(session_pid, :get_status)
      stored_team_id = GenServer.call(session_pid, :get_team_id)
      assert stored_team_id == team_id

      TeamManager.dissolve_team(team_id)
    end

    test "session tracks child teams and receives completion results", %{
      session_id: session_id,
      session_pid: session_pid
    } do
      # Wire a backing team
      {:ok, backing_id} =
        TeamManager.create_team(name: "backing-results", project_path: @project_path)

      send(session_pid, {:team_created, backing_id})
      Process.sleep(50)

      # Spawn a child team
      {:ok, child_id} =
        TeamManager.create_sub_team(backing_id, "architect",
          name: "child-results",
          project_path: @project_path
        )

      # Notify session about the child team
      send(session_pid, {:child_team_created, child_id})
      Process.sleep(50)

      assert_receive {:child_team_available, ^session_id, ^child_id}

      # Create and complete tasks in the child team
      {:ok, task} =
        Tasks.create_task(child_id, %{
          title: "Do the work",
          description: "Implement the feature"
        })

      {:ok, _} = Tasks.assign_task(task.id, "worker")
      {:ok, _} = Tasks.complete_task(task.id, "Feature complete")

      # Session should synthesize results and broadcast to chat
      Process.sleep(100)

      assert_receive {:new_message, ^session_id, %{role: :assistant, content: summary}}
      assert summary =~ "Do the work"
      assert summary =~ "Feature complete"

      TeamManager.dissolve_team(child_id)
      TeamManager.dissolve_team(backing_id)
    end
  end
end
