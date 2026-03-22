defmodule Loomkin.Teams.TasksTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Capabilities, Comms, Context, Manager, Tasks}

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

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:task_created, task_id, "Broadcast test"}}
                      }}

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

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:task_created, _, "Assign broadcast"}}
                      }}

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.assigned",
                        data: %{task_id: task_id, agent_name: "bob"}
                      }}

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

      assert_receive {:signal, %Jido.Signal{type: "team.task.completed", data: %{owner: "coder"}}}
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

      # Unblocking now goes through UpstreamVerifier (async) before broadcasting.
      # The verifier always unblocks dependents regardless of pass/fail, but it
      # runs in a Task process so we need a longer timeout.
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:tasks_unblocked, ids, _predecessor_outputs}}
                      }},
                     5_000

      assert blocked.id in ids
    end
  end

  # -- Smart Assignment --

  describe "smart_assign/2" do
    test "assigns to best capable idle agent", %{team_id: team_id} do
      # Register two idle agents
      Context.register_agent(team_id, "alice", %{role: :coder, status: :idle})
      Context.register_agent(team_id, "bob", %{role: :coder, status: :idle})

      # Give alice strong coding capability
      for _ <- 1..5, do: Capabilities.record_completion(team_id, "alice", :coding, :success)
      # Give bob weaker coding capability
      Capabilities.record_completion(team_id, "bob", :coding, :success)
      Capabilities.record_completion(team_id, "bob", :coding, :failure)

      {:ok, task} = Tasks.create_task(team_id, %{title: "Implement feature"})
      assert {:ok, assigned, reason} = Tasks.smart_assign(team_id, task.id)
      assert assigned.owner == "alice"
      assert reason =~ "Best at coding"
    end

    test "falls back to least-loaded agent when no capability data", %{team_id: team_id} do
      Context.register_agent(team_id, "alice", %{role: :coder, status: :idle})
      Context.register_agent(team_id, "bob", %{role: :coder, status: :idle})

      # Give alice an existing task to increase her load
      {:ok, existing} = Tasks.create_task(team_id, %{title: "Existing work"})
      Tasks.assign_task(existing.id, "alice")

      {:ok, task} = Tasks.create_task(team_id, %{title: "New work"})
      assert {:ok, assigned, reason} = Tasks.smart_assign(team_id, task.id)
      assert assigned.owner == "bob"
      assert reason =~ "Least loaded"
    end

    test "returns error when no idle agents", %{team_id: team_id} do
      Context.register_agent(team_id, "alice", %{role: :coder, status: :working})

      {:ok, task} = Tasks.create_task(team_id, %{title: "No one free"})
      assert {:error, :no_idle_agents} = Tasks.smart_assign(team_id, task.id)
    end

    test "returns error for non-existent task", %{team_id: team_id} do
      Context.register_agent(team_id, "alice", %{role: :coder, status: :idle})
      assert {:error, :not_found} = Tasks.smart_assign(team_id, Ecto.UUID.generate())
    end

    test "skips busy agents even if they have better capabilities", %{team_id: team_id} do
      Context.register_agent(team_id, "alice", %{role: :coder, status: :working})
      Context.register_agent(team_id, "bob", %{role: :coder, status: :idle})

      # Alice is better but busy
      for _ <- 1..5, do: Capabilities.record_completion(team_id, "alice", :coding, :success)

      {:ok, task} = Tasks.create_task(team_id, %{title: "Implement something"})
      assert {:ok, assigned, _reason} = Tasks.smart_assign(team_id, task.id)
      assert assigned.owner == "bob"
    end
  end

  # -- Partial Results --

  describe "mark_partially_complete/2 with structured data" do
    test "accepts structured partial data with progress tracking", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Multi-step task"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      partial_data = %{
        completed_items: 3,
        total_items: 10,
        output: "First 3 items processed",
        next_steps: "Continue with items 4-10"
      }

      assert {:ok, updated} = Tasks.mark_partially_complete(task.id, partial_data)
      assert updated.status == :partially_complete
      assert updated.completed_items == 3
      assert updated.total_items == 10
      assert updated.partial_results["completed_items"] == 3
      assert updated.partial_results["total_items"] == 10
      assert updated.partial_results["output"] == "First 3 items processed"
      assert updated.result =~ "3/10 items complete"
    end

    test "accepts string partial result for backward compatibility", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Simple partial"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      assert {:ok, updated} = Tasks.mark_partially_complete(task.id, "halfway done")
      assert updated.status == :partially_complete
      assert updated.partial_results["output"] == "halfway done"
    end

    test "rejects transition from non-in_progress status", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Not started"})

      assert {:error, :invalid_transition} =
               Tasks.mark_partially_complete(task.id, %{output: "nope"})
    end

    test "triggers auto_schedule_unblocked after partial completion", %{team_id: team_id} do
      {:ok, producer} = Tasks.create_task(team_id, %{title: "Producer"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Consumer"})
      Tasks.add_dependency(consumer.id, producer.id, :requires_output)

      Tasks.assign_task(producer.id, "coder")
      Tasks.start_task(producer.id)

      # Before partial completion, consumer is blocked
      available_before = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      refute consumer.id in available_before

      Tasks.mark_partially_complete(producer.id, %{output: "partial data"})

      # After partial completion, consumer should be unblocked
      available_after = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      assert consumer.id in available_after
    end
  end

  describe "partial results unblock dependents" do
    test "requires_output dep unblocks on partially_complete", %{team_id: team_id} do
      {:ok, producer} = Tasks.create_task(team_id, %{title: "Data producer"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Data consumer"})
      Tasks.add_dependency(consumer.id, producer.id, :requires_output)

      Tasks.assign_task(producer.id, "coder")
      Tasks.start_task(producer.id)
      Tasks.mark_partially_complete(producer.id, %{output: "partial output"})

      available = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      assert consumer.id in available
    end

    test "blocks dep does NOT unblock on partially_complete", %{team_id: team_id} do
      {:ok, blocker} = Tasks.create_task(team_id, %{title: "Blocker"})
      {:ok, blocked} = Tasks.create_task(team_id, %{title: "Blocked"})
      Tasks.add_dependency(blocked.id, blocker.id, :blocks)

      Tasks.assign_task(blocker.id, "coder")
      Tasks.start_task(blocker.id)
      Tasks.mark_partially_complete(blocker.id, %{output: "partial"})

      available = Tasks.list_available(team_id) |> Enum.map(& &1.id)
      refute blocked.id in available
    end

    test "get_predecessor_outputs includes partial results", %{team_id: team_id} do
      {:ok, producer} = Tasks.create_task(team_id, %{title: "Producer"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Consumer"})
      Tasks.add_dependency(consumer.id, producer.id, :requires_output)

      Tasks.assign_task(producer.id, "coder")
      Tasks.start_task(producer.id)

      Tasks.mark_partially_complete(producer.id, %{
        output: "partial data",
        completed_items: 2,
        total_items: 5
      })

      outputs = Tasks.get_predecessor_outputs(consumer.id)
      assert length(outputs) == 1
      output = hd(outputs)
      assert output.partial == true
      assert output.partial_results["output"] == "partial data"
    end
  end

  describe "resume_task/1" do
    test "resumes a partially complete task to in_progress", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Resume me"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)
      Tasks.mark_partially_complete(task.id, %{output: "halfway"})

      assert {:ok, resumed} = Tasks.resume_task(task.id)
      assert resumed.status == :in_progress
    end

    test "preserves partial_results after resume", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Resume with context"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      Tasks.mark_partially_complete(task.id, %{
        output: "progress",
        completed_items: 3,
        total_items: 10
      })

      {:ok, resumed} = Tasks.resume_task(task.id)
      assert resumed.partial_results["output"] == "progress"
      assert resumed.partial_results["completed_items"] == 3
    end

    test "rejects resume from non-partially_complete status", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Not partial"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      assert {:error, :invalid_transition} = Tasks.resume_task(task.id)
    end

    test "broadcasts task_resumed signal", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Resume broadcast"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)
      Tasks.mark_partially_complete(task.id, %{output: "partial"})
      Tasks.resume_task(task.id)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.task.resumed",
                        data: %{task_id: task_id, owner: "coder"}
                      }}

      assert task_id == task.id
    end

    test "can complete task after resume", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Full lifecycle"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)
      Tasks.mark_partially_complete(task.id, %{output: "first pass"})
      Tasks.resume_task(task.id)

      assert {:ok, completed} = Tasks.complete_task(task.id, "all done")
      assert completed.status == :completed
      assert completed.result == "all done"
    end
  end
end
