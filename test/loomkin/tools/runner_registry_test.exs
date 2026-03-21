defmodule Loomkin.Tools.RunnerRegistryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.RunnerRegistry

  setup do
    limits = %{shell: 2, file_write: 1, default: 1, total: 4}
    registry = start_supervised!({RunnerRegistry, name: nil, limits: limits})
    %{registry: registry}
  end

  describe "acquire/release" do
    test "acquire succeeds within limits", %{registry: registry} do
      assert :ok = RunnerRegistry.acquire(:shell, registry)
      assert %{by_type: %{shell: 1}, total: 1} = RunnerRegistry.status(registry)
    end

    test "release decrements the count", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:shell, registry)
      :ok = RunnerRegistry.release(:shell, registry)
      assert %{by_type: counts, total: 0} = RunnerRegistry.status(registry)
      refute Map.has_key?(counts, :shell)
    end

    test "rejects when per-type limit reached", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:shell, registry)
      :ok = RunnerRegistry.acquire(:shell, registry)
      assert {:error, :concurrency_limit} = RunnerRegistry.acquire(:shell, registry)
    end

    test "rejects when total limit reached", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:shell, registry)
      :ok = RunnerRegistry.acquire(:shell, registry)
      :ok = RunnerRegistry.acquire(:file_write, registry)
      :ok = RunnerRegistry.acquire(:file_read, registry)
      # total is 4, all slots full
      assert {:error, :concurrency_limit} = RunnerRegistry.acquire(:content_search, registry)
    end

    test "uses default limit for unknown tool types", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:some_tool, registry)
      # default limit is 1
      assert {:error, :concurrency_limit} = RunnerRegistry.acquire(:some_tool, registry)
    end

    test "release is idempotent for unreserved slots", %{registry: registry} do
      assert :ok = RunnerRegistry.release(:shell, registry)
      assert %{total: 0} = RunnerRegistry.status(registry)
    end

    test "release frees slot for new acquire", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:file_write, registry)
      assert {:error, :concurrency_limit} = RunnerRegistry.acquire(:file_write, registry)
      :ok = RunnerRegistry.release(:file_write, registry)
      assert :ok = RunnerRegistry.acquire(:file_write, registry)
    end
  end

  describe "with_limit/3" do
    test "executes function when slot is available", %{registry: registry} do
      result = RunnerRegistry.with_limit(:shell, registry, fn -> {:ok, "done"} end)
      assert result == {:ok, "done"}
      # slot released after function returns
      assert %{total: 0} = RunnerRegistry.status(registry)
    end

    test "returns error when slot unavailable", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:file_write, registry)
      result = RunnerRegistry.with_limit(:file_write, registry, fn -> :should_not_run end)
      assert result == {:error, :concurrency_limit}
    end

    test "releases slot even when function raises", %{registry: registry} do
      assert_raise RuntimeError, "boom", fn ->
        RunnerRegistry.with_limit(:shell, registry, fn -> raise "boom" end)
      end

      assert %{total: 0} = RunnerRegistry.status(registry)
    end
  end

  describe "process monitoring" do
    test "releases slots when holding process dies", %{registry: registry} do
      parent = self()

      pid =
        spawn(fn ->
          :ok = RunnerRegistry.acquire(:shell, registry)
          send(parent, :acquired)
          Process.sleep(:infinity)
        end)

      assert_receive :acquired
      assert %{total: 1} = RunnerRegistry.status(registry)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Give the registry time to process the DOWN message
      _ = RunnerRegistry.status(registry)

      assert %{total: 0} = RunnerRegistry.status(registry)
    end
  end

  describe "telemetry" do
    test "emits acquired event", %{registry: registry} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loomkin, :runner, :acquired]
        ])

      :ok = RunnerRegistry.acquire(:shell, registry)

      assert_receive {[:loomkin, :runner, :acquired], ^ref, %{count: 1, total: 1},
                      %{tool_type: :shell}}
    end

    test "emits released event", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:shell, registry)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loomkin, :runner, :released]
        ])

      :ok = RunnerRegistry.release(:shell, registry)

      assert_receive {[:loomkin, :runner, :released], ^ref, %{count: 0, total: 0},
                      %{tool_type: :shell}}
    end

    test "emits rejected event", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:file_write, registry)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loomkin, :runner, :rejected]
        ])

      {:error, :concurrency_limit} = RunnerRegistry.acquire(:file_write, registry)

      assert_receive {[:loomkin, :runner, :rejected], ^ref, %{count: 1},
                      %{tool_type: :file_write, reason: :concurrency_limit}}
    end
  end

  describe "status/1" do
    test "returns empty state initially", %{registry: registry} do
      assert %{by_type: %{}, total: 0} = RunnerRegistry.status(registry)
    end

    test "tracks multiple tool types independently", %{registry: registry} do
      :ok = RunnerRegistry.acquire(:shell, registry)
      :ok = RunnerRegistry.acquire(:file_write, registry)

      assert %{by_type: %{shell: 1, file_write: 1}, total: 2} =
               RunnerRegistry.status(registry)
    end
  end
end
