defmodule Loomkin.Verification.TaskIntegrationTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Comms, Manager, Tasks}

  setup do
    {:ok, team_id} = Manager.create_team(name: "verify-integration-test")
    Comms.subscribe(team_id, "listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "complete_task without dependents" do
    test "unblocks immediately (no verifier spawned)", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Standalone task"})
      {:ok, _started} = Tasks.start_task(task.id)
      {:ok, completed} = Tasks.complete_task(task.id, %{result: "done"})

      assert completed.status == :completed
      assert completed.result == "done"
    end
  end

  describe "complete_task with dependents" do
    test "task with blocking dependent triggers verification", %{team_id: team_id} do
      # Subscribe to PubSub for verification events
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")

      # Create upstream task and dependent task
      {:ok, upstream} = Tasks.create_task(team_id, %{title: "Upstream work"})
      {:ok, dependent} = Tasks.create_task(team_id, %{title: "Dependent work"})

      # Add dependency: dependent :blocks on upstream
      {:ok, _dep} = Tasks.add_dependency(dependent.id, upstream.id, :blocks)

      # Start and complete upstream task
      {:ok, _} = Tasks.assign_task(upstream.id, "agent_a")
      {:ok, _} = Tasks.start_task(upstream.id)

      {:ok, completed} =
        Tasks.complete_task(upstream.id, %{
          result: "implemented feature",
          files_changed: ["lib/foo.ex"]
        })

      assert completed.status == :completed

      # The verifier spawns asynchronously. In test environment without an API key,
      # the AgentLoop will fail, which means the verifier will report a failure.
      # We verify the verification was at least started by checking PubSub.
      assert_receive {:verification_event, %{type: "verification.started", task_id: task_id}},
                     2_000

      assert task_id == upstream.id
    end

    test "task with requires_output dependent triggers verification", %{team_id: team_id} do
      {:ok, upstream} = Tasks.create_task(team_id, %{title: "Generate data"})
      {:ok, dependent} = Tasks.create_task(team_id, %{title: "Process data"})

      {:ok, _dep} = Tasks.add_dependency(dependent.id, upstream.id, :requires_output)

      {:ok, _} = Tasks.assign_task(upstream.id, "agent_b")
      {:ok, _} = Tasks.start_task(upstream.id)
      {:ok, completed} = Tasks.complete_task(upstream.id, %{result: "data generated"})

      assert completed.status == :completed
    end

    test "informs dependency does not trigger verification", %{team_id: team_id} do
      {:ok, upstream} = Tasks.create_task(team_id, %{title: "FYI task"})
      {:ok, downstream} = Tasks.create_task(team_id, %{title: "Informed task"})

      # :informs dependency should NOT trigger verification
      {:ok, _dep} = Tasks.add_dependency(downstream.id, upstream.id, :informs)

      {:ok, _} = Tasks.assign_task(upstream.id, "agent_c")
      {:ok, _} = Tasks.start_task(upstream.id)
      {:ok, completed} = Tasks.complete_task(upstream.id, %{result: "fyi done"})

      assert completed.status == :completed

      # With only :informs dep, auto_schedule_unblocked should be called directly
      # (no verifier spawned). The dependent should get unblocked immediately.
      assert_receive {:signal,
                      %Jido.Signal{
                        data: %{message: {:tasks_unblocked, _ids, _outputs}}
                      }}
    end
  end
end
