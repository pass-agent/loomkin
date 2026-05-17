defmodule Loomkin.Orchestration.PRShepherd.ServerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.PRShepherd.GitHubClient.Stub
  alias Loomkin.Orchestration.PRShepherd.Server

  setup do
    Stub.reset()

    # Each test gets a unique PR ref so the via-registry doesn't collide.
    n = System.unique_integer([:positive])
    pr_ref = {"acme", "widgets", n}

    on_exit(fn ->
      case Server.whereis(pr_ref) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end

      Stub.reset()
    end)

    {:ok, pr_ref: pr_ref}
  end

  defp wait_until(pr_ref, target, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(pr_ref, target, deadline)
  end

  defp do_wait_until(pr_ref, target, deadline) do
    snapshot = Server.status(pr_ref)

    cond do
      snapshot.state == target ->
        snapshot

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out; last state: #{inspect(snapshot.state)} (target: #{inspect(target)})")

      true ->
        Process.sleep(10)
        do_wait_until(pr_ref, target, deadline)
    end
  end

  defp start_shepherd(pr_ref, extra_opts \\ []) do
    opts =
      [
        pr_ref: pr_ref,
        epic_id: "epic-test-#{elem(pr_ref, 2)}",
        github_client: Stub,
        poll_interval_ms: 25
      ] ++ extra_opts

    start_supervised!({Server, opts})
  end

  describe "polling and transitions" do
    test "transitions :monitoring → :ready when CI green and no unresolved comments",
         %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, %{ci: :success, comments: []})
      start_shepherd(pr_ref)

      snap = wait_until(pr_ref, :ready)
      assert snap.ci == :success
      assert snap.unresolved_count == 0
    end

    test "transitions :monitoring → :failed when CI is red", %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, %{ci: :failure, comments: []})
      start_shepherd(pr_ref)

      snap = wait_until(pr_ref, :failed)
      assert snap.reason == :ci_failure
      assert snap.ci == :failure
    end

    test "transitions :monitoring → :comments_pending when CI green but comments unresolved",
         %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, %{
        ci: :success,
        comments: [
          %{id: 1, body: "nit", resolved: false},
          %{id: 2, body: "fix", resolved: true}
        ]
      })

      start_shepherd(pr_ref)

      snap = wait_until(pr_ref, :comments_pending)
      assert snap.ci == :success
      assert snap.unresolved_count == 1
    end

    test "comments_pending → ready once comments get resolved", %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, %{
        ci: :success,
        comments: [%{id: 1, body: "nit", resolved: false}]
      })

      start_shepherd(pr_ref)
      _ = wait_until(pr_ref, :comments_pending)

      Stub.put_status(pr_ref, %{
        ci: :success,
        comments: [%{id: 1, body: "nit", resolved: true}]
      })

      snap = wait_until(pr_ref, :ready)
      assert snap.unresolved_count == 0
    end

    test "errors from the client convert to :failed", %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, {:error, :boom})
      start_shepherd(pr_ref)

      snap = wait_until(pr_ref, :failed)
      assert match?({:client_error, :boom}, snap.reason)
    end

    test "broadcasts on the orchestration.pr_shepherd topic", %{pr_ref: pr_ref} do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, Server.topic())
      Stub.put_status(pr_ref, %{ci: :success, comments: []})
      start_shepherd(pr_ref)

      assert_receive {:pr_shepherd, ^pr_ref, :ready, %{epic_id: epic_id}}, 2_000
      assert is_binary(epic_id)
    end
  end

  describe "lifecycle" do
    test "stop/1 cancels timers and halts the GenServer", %{pr_ref: pr_ref} do
      Stub.put_status(pr_ref, %{ci: :pending, comments: []})
      pid = start_shepherd(pr_ref)
      assert Process.alive?(pid)

      ref = Process.monitor(pid)
      Server.stop(pr_ref)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # The Registry unregister runs async after the monitored process dies;
      # spin briefly until the slot frees up.
      deadline = System.monotonic_time(:millisecond) + 500

      wait_for_unregister = fn loop ->
        case Server.whereis(pr_ref) do
          nil ->
            :ok

          _ ->
            if System.monotonic_time(:millisecond) > deadline do
              flunk("registry never freed slot for #{inspect(pr_ref)}")
            else
              Process.sleep(5)
              loop.(loop)
            end
        end
      end

      wait_for_unregister.(wait_for_unregister)
    end
  end
end
