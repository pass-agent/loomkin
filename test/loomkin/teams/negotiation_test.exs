defmodule Loomkin.Teams.NegotiationTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Negotiation
  alias Loomkin.Teams.Tasks

  setup do
    {:ok, team_id} = Manager.create_team(name: "negotiation-test")
    start_supervised!({Negotiation, team_id: team_id})
    Comms.subscribe(team_id, "listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    {:ok, task} = Tasks.create_task(team_id, %{title: "Negotiable task"})

    %{team_id: team_id, task: task}
  end

  describe "start_negotiation/4" do
    test "starts a negotiation for a task", %{team_id: team_id, task: task} do
      assert {:ok, task_id} = Negotiation.start_negotiation(team_id, task.id, "alice")
      assert task_id == task.id
    end

    test "rejects duplicate negotiation for same task", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")

      assert {:error, :already_negotiating} =
               Negotiation.start_negotiation(team_id, task.id, "bob")
    end

    test "publishes negotiation started signal", %{team_id: team_id, task: task} do
      Negotiation.start_negotiation(team_id, task.id, "alice")

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.negotiation.started",
                        data: %{task_id: task_id, agent_name: "alice"}
                      }}

      assert task_id == task.id
    end
  end

  describe "respond/3 accept" do
    test "accepts a negotiation", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      assert :ok = Negotiation.respond(team_id, task.id, :accept)

      # Negotiation should be removed
      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)
    end

    test "publishes resolved signal on accept", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      Negotiation.respond(team_id, task.id, :accept)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.negotiation.resolved",
                        data: %{task_id: _, agent_name: "alice", resolution: "accepted"}
                      }}
    end
  end

  describe "respond/3 negotiate" do
    test "transitions to negotiating status with counter-proposal", %{
      team_id: team_id,
      task: task
    } do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")

      assert :ok =
               Negotiation.respond(
                 team_id,
                 task.id,
                 {:negotiate, "too complex", "split into subtasks"}
               )

      assert {:ok, status} = Negotiation.negotiation_status(team_id, task.id)
      assert status.status == :negotiating
      assert status.proposal.reason == "too complex"
      assert status.proposal.counter_proposal == "split into subtasks"
    end

    test "publishes offer signal", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      Negotiation.respond(team_id, task.id, {:negotiate, "wrong skill", "assign to bob"})

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.negotiation.offer",
                        data: %{
                          task_id: _,
                          agent_name: "alice",
                          reason: "wrong skill",
                          counter_proposal: "assign to bob"
                        }
                      }}
    end
  end

  describe "respond/3 decline" do
    test "declines a negotiation", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      assert :ok = Negotiation.respond(team_id, task.id, :decline)

      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)
    end
  end

  describe "resolve/3" do
    test "resolves a negotiating task", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      :ok = Negotiation.respond(team_id, task.id, {:negotiate, "reason", "proposal"})
      assert :ok = Negotiation.resolve(team_id, task.id, :accept_negotiation)

      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)
    end

    test "rejects resolve on pending_response status", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")

      assert {:error, {:invalid_status, :pending_response}} =
               Negotiation.resolve(team_id, task.id, :override)
    end

    test "publishes resolved signal", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      :ok = Negotiation.respond(team_id, task.id, {:negotiate, "r", "p"})
      Negotiation.resolve(team_id, task.id, :override)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.negotiation.resolved",
                        data: %{resolution: "override"}
                      }}
    end
  end

  describe "cancel/2" do
    test "cancels a pending negotiation", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      assert :ok = Negotiation.cancel(team_id, task.id)
      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)
    end

    test "returns error for unknown task", %{team_id: team_id} do
      assert {:error, :negotiation_not_found} = Negotiation.cancel(team_id, "nonexistent")
    end
  end

  describe "timeout auto-accept" do
    test "auto-accepts after timeout", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice", timeout_ms: 50)

      # Wait for timeout
      Process.sleep(100)

      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.negotiation.timed_out",
                        data: %{task_id: _, agent_name: "alice"}
                      }}
    end
  end

  describe "concurrent negotiations" do
    test "supports multiple negotiations for different tasks", %{team_id: team_id} do
      {:ok, task1} = Tasks.create_task(team_id, %{title: "Task 1"})
      {:ok, task2} = Tasks.create_task(team_id, %{title: "Task 2"})

      assert {:ok, _} = Negotiation.start_negotiation(team_id, task1.id, "alice")
      assert {:ok, _} = Negotiation.start_negotiation(team_id, task2.id, "bob")

      negotiations = Negotiation.list_negotiations(team_id)
      assert length(negotiations) == 2

      # Resolve one, the other stays
      :ok = Negotiation.respond(team_id, task1.id, :accept)
      negotiations = Negotiation.list_negotiations(team_id)
      assert length(negotiations) == 1
      assert hd(negotiations).task_id == task2.id
    end
  end

  describe "list_negotiations/1" do
    test "returns empty list when no negotiations", %{team_id: team_id} do
      assert Negotiation.list_negotiations(team_id) == []
    end

    test "returns all active negotiations", %{team_id: team_id, task: task} do
      {:ok, _} = Negotiation.start_negotiation(team_id, task.id, "alice")
      negotiations = Negotiation.list_negotiations(team_id)
      assert length(negotiations) == 1
      assert hd(negotiations).agent_name == "alice"
      assert hd(negotiations).status == :pending_response
    end
  end

  describe "integration with assign_task" do
    test "assign_task with negotiable: true starts negotiation", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Negotiable assign"})
      {:ok, _assigned} = Tasks.assign_task(task.id, "alice", negotiable: true, timeout_ms: 5_000)

      assert {:ok, status} = Negotiation.negotiation_status(team_id, task.id)
      assert status.agent_name == "alice"
      assert status.status == :pending_response
    end

    test "assign_task without negotiable does not start negotiation", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Normal assign"})
      {:ok, _assigned} = Tasks.assign_task(task.id, "alice")

      assert {:error, :negotiation_not_found} = Negotiation.negotiation_status(team_id, task.id)
    end
  end
end
