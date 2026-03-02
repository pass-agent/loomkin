defmodule Loomkin.Teams.TasksTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Comms, Context, Manager, Tasks}

  setup do
    {:ok, team_id} = Manager.create_team(name: "tasks-test")
    Comms.subscribe(team_id, "listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  # -- CRUD --

  describe "create_task/2" do
    test "creates a pending task", %{team_id: team_id} do
      assert {:ok, task} = Tasks.create_task(team_id, %{title: "Fix bug"})
      assert task.team_id == team_id
      assert task.title == "Fix bug"
      assert task.status == :pending
      assert task.priority == 3
    end

    test "broadcasts task_created event", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Broadcast test"})
      assert_receive {:task_created, task_id, "Broadcast test"}
      assert task_id == task.id
    end

    test "caches the task in ETS", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Cache test"})
      assert {:ok, cached} = Context.get_cached_task(team_id, task.id)
      assert cached.title == "Cache test"
      assert cached.status == :pending
    end

    test "returns error on missing title", %{team_id: team_id} do
      assert {:error, _changeset} = Tasks.create_task(team_id, %{})
    end
  end

  describe "assign_task/2" do
    test "assigns a task to an agent", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Assign me"})
      assert {:ok, updated} = Tasks.assign_task(task.id, "alice")
      assert updated.owner == "alice"
      assert updated.status == :assigned
    end

    test "broadcasts task_assigned event", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Assign broadcast"})
      Tasks.assign_task(task.id, "bob")

      assert_receive {:task_created, _, "Assign broadcast"}
      assert_receive {:task_assigned, task_id, "bob"}
      assert task_id == task.id
    end
  end

  describe "start_task/1" do
    test "moves task to in_progress", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Start me"})
      Tasks.assign_task(task.id, "coder")
      assert {:ok, updated} = Tasks.start_task(task.id)
      assert updated.status == :in_progress
    end
  end

  describe "complete_task/2" do
    test "moves task to completed with result", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Complete me"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)
      assert {:ok, updated} = Tasks.complete_task(task.id, "All done")
      assert updated.status == :completed
      assert updated.result == "All done"
    end

    test "broadcasts task_completed event", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Complete broadcast"})
      Tasks.assign_task(task.id, "coder")
      Tasks.complete_task(task.id, "done")

      assert_receive {:task_completed, _, "coder", "done"}
    end
  end

  describe "fail_task/2" do
    test "moves task to failed with reason", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Fail me"})
      Tasks.assign_task(task.id, "coder")
      assert {:ok, updated} = Tasks.fail_task(task.id, "compilation error")
      assert updated.status == :failed
      assert updated.result == "compilation error"
    end
  end

  describe "get_task/1" do
    test "returns {:ok, task} for existing", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Find me"})
      assert {:ok, found} = Tasks.get_task(task.id)
      assert found.id == task.id
    end

    test "returns {:error, :not_found} for missing" do
      assert {:error, :not_found} = Tasks.get_task(Ecto.UUID.generate())
    end
  end

  # -- Queries --

  describe "list_all/1" do
    test "returns all tasks for a team", %{team_id: team_id} do
      Tasks.create_task(team_id, %{title: "T1"})
      Tasks.create_task(team_id, %{title: "T2"})
      Tasks.create_task(team_id, %{title: "T3"})
      assert length(Tasks.list_all(team_id)) == 3
    end

    test "orders by priority then inserted_at", %{team_id: team_id} do
      Tasks.create_task(team_id, %{title: "Low", priority: 5})
      Tasks.create_task(team_id, %{title: "High", priority: 1})
      Tasks.create_task(team_id, %{title: "Mid", priority: 3})

      titles = Tasks.list_all(team_id) |> Enum.map(& &1.title)
      assert titles == ["High", "Mid", "Low"]
    end
  end

  describe "list_by_agent/2" do
    test "returns only tasks owned by the agent", %{team_id: team_id} do
      {:ok, t1} = Tasks.create_task(team_id, %{title: "Alice's"})
      {:ok, t2} = Tasks.create_task(team_id, %{title: "Bob's"})
      Tasks.assign_task(t1.id, "alice")
      Tasks.assign_task(t2.id, "bob")

      alice_tasks = Tasks.list_by_agent(team_id, "alice")
      assert length(alice_tasks) == 1
      assert hd(alice_tasks).title == "Alice's"
    end
  end

  # -- Dependencies --

  describe "add_dependency/3" do
    test "creates a dependency between tasks", %{team_id: team_id} do
      {:ok, t1} = Tasks.create_task(team_id, %{title: "First"})
      {:ok, t2} = Tasks.create_task(team_id, %{title: "Second"})
      assert {:ok, dep} = Tasks.add_dependency(t2.id, t1.id, :blocks)
      assert dep.task_id == t2.id
      assert dep.depends_on_id == t1.id
      assert dep.dep_type == :blocks
    end
  end

  describe "list_available/1" do
    test "returns pending tasks without blocking deps", %{team_id: team_id} do
      {:ok, t1} = Tasks.create_task(team_id, %{title: "Independent"})
      {:ok, t2} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, t3} = Tasks.create_task(team_id, %{title: "Blocked"})

      Tasks.add_dependency(t3.id, t2.id, :blocks)

      available = Tasks.list_available(team_id)
      ids = Enum.map(available, & &1.id)

      assert t1.id in ids
      assert t2.id in ids
      refute t3.id in ids
    end

    test "blocked task becomes available once blocker completes", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :blocks)

      # Before completion: blocked is not available
      available_before = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      refute blocked.id in available_before

      # Complete the blocker
      Tasks.assign_task(blocker.id, "coder")
      Tasks.complete_task(blocker.id, "done")

      # After completion: blocked is now available
      available_after = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      assert blocked.id in available_after
    end

    test "informs deps do not block", %{team_id: team_id} do
      {:ok, t1} = Tasks.create_task(team_id, %{title: "Informer"})
      {:ok, t2} = Tasks.create_task(team_id, %{title: "Informed"})
      Tasks.add_dependency(t2.id, t1.id, :informs)

      available = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      assert t2.id in available
    end
  end

  describe "auto_schedule_unblocked/1" do
    test "broadcasts tasks_unblocked when blocker completes", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :blocks)

      Tasks.assign_task(blocker.id, "coder")
      Tasks.complete_task(blocker.id, "done")

      assert_receive {:tasks_unblocked, ids}
      assert blocked.id in ids
    end
  end
end
