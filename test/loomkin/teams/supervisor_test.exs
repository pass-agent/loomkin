defmodule Loomkin.Teams.SupervisorTest do
  use ExUnit.Case, async: true

  describe "Teams.Supervisor" do
    test "supervisor is started and running" do
      pid = Process.whereis(Loomkin.Teams.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "AgentRegistry is accessible" do
      pid = Process.whereis(Loomkin.Teams.AgentRegistry)
      assert is_pid(pid)
    end

    test "AgentSupervisor is accessible" do
      pid = Process.whereis(Loomkin.Teams.AgentSupervisor)
      assert is_pid(pid)
    end

    test "RateLimiter is accessible" do
      pid = Process.whereis(Loomkin.Teams.RateLimiter)
      assert is_pid(pid)
    end

    test "TaskSupervisor is accessible" do
      pid = Process.whereis(Loomkin.Teams.TaskSupervisor)
      assert is_pid(pid)
    end

    test "AgentRegistry can register and lookup processes" do
      key = "test-agent-#{System.unique_integer([:positive])}"

      {:ok, _} = Registry.register(Loomkin.Teams.AgentRegistry, key, :test)

      assert [{self_pid, :test}] = Registry.lookup(Loomkin.Teams.AgentRegistry, key)
      assert self_pid == self()
    end
  end
end
