defmodule Loomkin.Teams.SpeculativeTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Tasks

  setup do
    {:ok, team_id} = Manager.create_team(name: "speculative-test")
    Comms.subscribe(team_id, "listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "start_speculative/3" do
    test "starts speculative execution with assumption recording", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :requires_output)

      assert {:ok, spec_task} =
               Tasks.start_speculative(blocked.id, blocker.id, "expected output")

      assert spec_task.status == :pending_speculative
      assert spec_task.speculative == true
      assert spec_task.based_on_tentative == blocker.id
      assert Decimal.equal?(spec_task.confidence, Decimal.new("0.5"))
    end

    test "rejects start_speculative on non-pending/blocked tasks", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Active"})
      Tasks.assign_task(task.id, "agent")
      Tasks.start_task(task.id)

      assert {:error, :invalid_transition} =
               Tasks.start_speculative(task.id, blocker.id, "assumed")
    end

    test "broadcasts TaskSpeculativeStarted signal", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})

      Tasks.start_speculative(blocked.id, blocker.id, "expected output")

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.speculative.started",
                        data: %{task_id: task_id, based_on_task_id: blocker_id}
                      }}

      assert task_id == blocked.id
      assert blocker_id == blocker.id
    end
  end

  describe "validate_assumptions/1" do
    test "all match when blocker output matches assumed value", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :requires_output)

      Tasks.start_speculative(blocked.id, blocker.id, "correct output")

      # Set blocker result directly to test validate_assumptions in isolation
      blocker_task = Loomkin.Repo.get!(Loomkin.Schemas.TeamTask, blocker.id)

      blocker_task
      |> Loomkin.Schemas.TeamTask.changeset(%{status: :completed, result: "correct output"})
      |> Loomkin.Repo.update!()

      assert {:ok, true} = Tasks.validate_assumptions(blocked.id)
    end

    test "returns mismatches when blocker output differs", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :requires_output)

      Tasks.start_speculative(blocked.id, blocker.id, "expected output")

      # Complete blocker with different output — but DON'T use complete_task
      # which would trigger auto-validation. Instead, manually set the result
      # to test validate_assumptions in isolation.
      blocker_task = Loomkin.Repo.get!(Loomkin.Schemas.TeamTask, blocker.id)

      blocker_task
      |> Loomkin.Schemas.TeamTask.changeset(%{status: :completed, result: "different output"})
      |> Loomkin.Repo.update!()

      assert {:error, mismatches} = Tasks.validate_assumptions(blocked.id)
      assert length(mismatches) == 1
      assert hd(mismatches).key == "blocker_output"
      assert hd(mismatches).assumed == "expected output"
      assert hd(mismatches).actual == "different output"
    end

    test "returns error for non-speculative task", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Normal"})

      assert {:error, :not_speculative} = Tasks.validate_assumptions(task.id)
    end
  end

  describe "auto-validation on blocker completion" do
    test "auto-confirms tentative task when assumptions match", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Speculative"})
      Tasks.add_dependency(blocked.id, blocker.id, :requires_output)

      # Start speculative and mark tentatively complete
      Tasks.start_speculative(blocked.id, blocker.id, "the answer")
      Tasks.complete_speculative(blocked.id, "speculative result")

      # Complete the blocker with matching output — triggers auto-validation
      Tasks.assign_task(blocker.id, "agent")
      Tasks.complete_task(blocker.id, "the answer")

      {:ok, confirmed_task} = Tasks.get_task(blocked.id)
      assert confirmed_task.status == :completed

      assert_receive {:signal,
                      %Jido.Signal{type: "team.task.speculative.confirmed", data: %{task_id: _}}}
    end

    test "auto-discards tentative task when assumptions mismatch", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Speculative"})
      Tasks.add_dependency(blocked.id, blocker.id, :requires_output)

      Tasks.start_speculative(blocked.id, blocker.id, "expected")
      Tasks.complete_speculative(blocked.id, "speculative result")

      # Complete blocker with mismatching output
      Tasks.assign_task(blocker.id, "agent")
      Tasks.complete_task(blocker.id, "actual different")

      # Task should be re-queued as pending
      {:ok, requeued_task} = Tasks.get_task(blocked.id)
      assert requeued_task.status == :pending
      assert requeued_task.speculative == false

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.assumption.violated",
                        data: %{task_id: _, assumption_key: "blocker_output"}
                      }}

      assert_receive {:signal,
                      %Jido.Signal{type: "team.task.speculative.discarded", data: %{task_id: _}}}
    end
  end

  describe "confirm_tentative/1" do
    test "transitions completed_tentative to completed", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")
      Tasks.complete_speculative(task.id, "result")

      assert {:ok, confirmed} = Tasks.confirm_tentative(task.id)
      assert confirmed.status == :completed
      assert Decimal.equal?(confirmed.confidence, Decimal.new("1.0"))
    end

    test "rejects confirm on non-tentative task", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Normal"})

      assert {:error, :invalid_transition} = Tasks.confirm_tentative(task.id)
    end

    test "broadcasts SpeculativeConfirmed signal", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")
      Tasks.complete_speculative(task.id, "result")
      Tasks.confirm_tentative(task.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.speculative.confirmed",
                        data: %{task_id: task_id}
                      }}

      assert task_id == task.id
    end
  end

  describe "discard_tentative/1" do
    test "transitions to discarded_tentative", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")
      Tasks.complete_speculative(task.id, "result")

      assert {:ok, discarded} = Tasks.discard_tentative(task.id)
      assert discarded.status == :discarded_tentative
    end

    test "re-queues when requeue: true", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")
      Tasks.complete_speculative(task.id, "result")
      Tasks.discard_tentative(task.id, requeue: true)

      {:ok, requeued} = Tasks.get_task(task.id)
      assert requeued.status == :pending
      assert requeued.speculative == false
      assert requeued.based_on_tentative == nil
    end

    test "rejects discard on non-speculative statuses", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Normal"})

      assert {:error, :invalid_transition} = Tasks.discard_tentative(task.id)
    end

    test "broadcasts SpeculativeDiscarded signal", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")
      Tasks.discard_tentative(task.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.speculative.discarded",
                        data: %{task_id: task_id}
                      }}

      assert task_id == task.id
    end
  end

  describe "complete_speculative/2" do
    test "marks speculative task as completed_tentative", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, task} = Tasks.create_task(team_id, %{title: "Speculative"})

      Tasks.start_speculative(task.id, blocker.id, "assumed")

      assert {:ok, tentative} = Tasks.complete_speculative(task.id, "tentative result")
      assert tentative.status == :completed_tentative
      assert tentative.result == "tentative result"
    end

    test "rejects on non-speculative task", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Normal"})

      assert {:error, :invalid_transition} = Tasks.complete_speculative(task.id, "result")
    end
  end
end
