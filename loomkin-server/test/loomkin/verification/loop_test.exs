defmodule Loomkin.Verification.LoopTest do
  use ExUnit.Case, async: false

  alias Loomkin.Verification.Loop

  @team_id "loop-test-team"

  defp start_loop(overrides) do
    id = Keyword.get_lazy(overrides, :id, &Ecto.UUID.generate/0)
    task_id = Keyword.get_lazy(overrides, :task_id, &Ecto.UUID.generate/0)

    opts =
      [
        id: id,
        workspace_id: nil,
        team_id: @team_id,
        task_id: task_id,
        test_command: Keyword.get(overrides, :test_command, "true"),
        project_path: Keyword.get(overrides, :project_path, "/tmp"),
        max_iterations: Keyword.get(overrides, :max_iterations, 10),
        timeout_ms: Keyword.get(overrides, :timeout_ms, :timer.minutes(5))
      ]
      |> Keyword.merge(overrides)

    pid = start_supervised!({Loop, opts}, id: id)
    %{pid: pid, id: id, task_id: task_id}
  end

  describe "independent completion" do
    test "loop passes when test command succeeds on first iteration" do
      %{pid: pid} = start_loop(test_command: "true", max_iterations: 3)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "loop fails after max iterations when command always fails" do
      %{pid: pid} = start_loop(test_command: "false", max_iterations: 2)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    end

    test "status returns current state while loop running" do
      id = Ecto.UUID.generate()
      # Use a command that fails so the loop iterates (not immediate exit)
      %{pid: _pid} =
        start_loop(
          id: id,
          test_command: "false",
          max_iterations: 100,
          timeout_ms: 30_000
        )

      # Give the loop a moment to start its first async test task
      _ = :sys.get_state(via(id))

      {:ok, status} = Loop.status(id)
      assert status.id == id
      assert status.status == :running
      assert status.max_iterations == 100
    end

    test "status returns not_found for unknown id" do
      assert {:error, :not_found} = Loop.status("nonexistent-id")
    end
  end

  describe "steering" do
    test "steer injects guidance into state" do
      id = Ecto.UUID.generate()

      # Use a slow command so iterations don't complete between steer and state read
      %{pid: _pid} =
        start_loop(
          id: id,
          test_command: "sleep 30",
          max_iterations: 100,
          timeout_ms: 60_000
        )

      # Synchronize to ensure init completes and test task is spawned
      _ = :sys.get_state(via(id))

      assert :ok = Loop.steer(id, "try approach X")

      state = :sys.get_state(via(id))
      assert state.steering == "try approach X"
    end

    test "steer returns not_found for unknown id" do
      assert {:error, :not_found} = Loop.steer("nonexistent-id", "hint")
    end
  end

  describe "stop" do
    test "stop gracefully terminates the loop" do
      id = Ecto.UUID.generate()

      %{pid: pid} =
        start_loop(
          id: id,
          test_command: "false",
          max_iterations: 100,
          timeout_ms: 30_000
        )

      # Synchronize to ensure init completes
      _ = :sys.get_state(via(id))

      ref = Process.monitor(pid)
      assert :ok = Loop.stop(id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "stop returns not_found for unknown id" do
      assert {:error, :not_found} = Loop.stop("nonexistent-id")
    end
  end

  describe "timeout escalation" do
    test "loop stops on timeout" do
      # Use a slow command that won't finish before the short timeout
      %{pid: pid} =
        start_loop(
          test_command: "sleep 30",
          max_iterations: 100,
          timeout_ms: 200
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "confidence tracking" do
    test "loop exits normally when tests pass on first iteration" do
      id = Ecto.UUID.generate()
      %{pid: pid} = start_loop(id: id, test_command: "true", max_iterations: 1)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  defp via(id) do
    {:via, Registry, {Loomkin.Verification.Registry, id}}
  end
end
