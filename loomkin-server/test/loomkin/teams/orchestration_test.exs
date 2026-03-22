defmodule Loomkin.Teams.OrchestrationTest do
  @moduledoc """
  End-to-end integration test for team orchestration.
  Exercises task lifecycle and session integration with signal-based communication.
  """

  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Agent, Tasks}
  alias Loomkin.Teams.Manager, as: TeamManager
  alias Loomkin.Session.Manager, as: SessionManager

  @project_path "/tmp/loom-orchestration-test"

  setup do
    File.mkdir_p!(@project_path)

    session_id = Ecto.UUID.generate()

    {:ok, session_pid} =
      SessionManager.start_session(
        session_id: session_id,
        model: "test:model",
        project_path: @project_path
      )

    # Subscribe to session and team signals via the Bus
    Loomkin.Signals.subscribe("session.**")
    Loomkin.Signals.subscribe("team.**")
    Loomkin.Signals.subscribe("agent.**")
    Loomkin.Signals.subscribe("collaboration.**")

    on_exit(fn ->
      File.rm_rf!(@project_path)
    end)

    %{session_id: session_id, session_pid: session_pid}
  end

  describe "signal event ordering" do
    test "events fire in correct sequence during task lifecycle", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "event-order", project_path: @project_path)

      {:ok, _agent_pid} =
        TeamManager.spawn_agent(team_id, "worker", :coder, project_path: @project_path)

      # Agent init broadcast
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "agent.status",
                        data: %{agent_name: "worker", status: :idle}
                      }},
                     500

      # Task lifecycle
      {:ok, task} = Tasks.create_task(team_id, %{title: "Ordered task"})

      # task_created is broadcast as a generic peer message via Comms
      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500

      {:ok, _} = Tasks.assign_task(task.id, "worker")

      assert_receive {:signal,
                      %Jido.Signal{type: "team.task.assigned", data: %{task_id: task_id}}},
                     500

      assert task_id == task.id

      {:ok, _} = Tasks.start_task(task.id)
      assert_receive {:signal, %Jido.Signal{type: "team.task.started"}}, 500

      {:ok, _} = Tasks.complete_task(task.id, "done")
      assert_receive {:signal, %Jido.Signal{type: "team.task.completed"}}, 500

      TeamManager.dissolve_team(team_id)
    end

    test "failed task emits correct event", %{session_id: _session_id} do
      {:ok, team_id} =
        TeamManager.create_team(name: "fail-test", project_path: @project_path)

      {:ok, task} = Tasks.create_task(team_id, %{title: "Doomed task"})
      {:ok, _} = Tasks.assign_task(task.id, "worker")
      {:ok, _} = Tasks.fail_task(task.id, "compilation error")

      assert_receive {:signal, %Jido.Signal{type: "team.task.failed"}}, 500

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

      # Send context updates directly to agents (bypassing comms)
      send(pid1, {:context_update, "lead", %{plan: "build feature X"}})
      send(pid2, {:context_update, "lead", %{plan: "build feature X"}})

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

      sender_history = Agent.get_history(pid1)
      assert sender_history == []

      TeamManager.dissolve_team(team_id)
    end
  end

  describe "session integration" do
    test "session tracks backing team", %{session_pid: session_pid} do
      {:ok, team_id} =
        TeamManager.create_team(name: "session-team", project_path: @project_path)

      send(session_pid, {:team_created, team_id})

      assert_receive {:signal, %Jido.Signal{type: "session.team.available"}}, 1000

      {:ok, :idle} = GenServer.call(session_pid, :get_status)
      stored_team_id = GenServer.call(session_pid, :get_team_id)
      assert stored_team_id == team_id

      TeamManager.dissolve_team(team_id)
    end

    test "session tracks child teams and receives completion results", %{
      session_pid: session_pid
    } do
      {:ok, backing_id} =
        TeamManager.create_team(name: "backing-results", project_path: @project_path)

      send(session_pid, {:team_created, backing_id})
      Process.sleep(50)

      {:ok, child_id} =
        TeamManager.create_sub_team(backing_id, "architect",
          name: "child-results",
          project_path: @project_path
        )

      send(session_pid, {:child_team_created, child_id})
      Process.sleep(50)

      assert_receive {:signal, %Jido.Signal{type: "session.child_team.available"}}, 500

      {:ok, task} =
        Tasks.create_task(child_id, %{
          title: "Do the work",
          description: "Implement the feature"
        })

      {:ok, _} = Tasks.assign_task(task.id, "worker")
      {:ok, _} = Tasks.complete_task(task.id, "Feature complete")

      Process.sleep(100)

      assert_receive {:signal, %Jido.Signal{type: "session.message.new"}}, 1000

      TeamManager.dissolve_team(child_id)
      TeamManager.dissolve_team(backing_id)
    end
  end
end
