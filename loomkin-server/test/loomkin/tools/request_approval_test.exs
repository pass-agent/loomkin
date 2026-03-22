defmodule Loomkin.Tools.RequestApprovalTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.RequestApproval
  alias Loomkin.Signals.Approval

  @context %{team_id: "team-001", agent_name: "agent-alpha"}

  describe "module existence" do
    test "Loomkin.Tools.RequestApproval module exists" do
      assert Code.ensure_loaded?(RequestApproval)
    end
  end

  describe "run/2 approval response" do
    test "returns {:ok, %{status: :approved}} when response sent before timeout" do
      params = %{question: "Proceed with deployment?"}

      task =
        Task.async(fn ->
          RequestApproval.run(params, @context)
        end)

      # Give the tool task time to register in the registry
      Process.sleep(50)

      # Find the registry key and send the approval response
      gate_keys = Registry.keys(Loomkin.Teams.AgentRegistry, task.pid)
      assert [{:approval_gate, gate_id}] = gate_keys

      send(task.pid, {:approval_response, gate_id, %{outcome: :approved, context: "LGTM"}})

      assert {:ok, result} = Task.await(task, 1000)
      assert result.status == :approved
      assert result.message == "Approved by human."
      assert result.context == "LGTM"
      assert result.reason == nil
    end

    test "returns {:ok, %{status: :denied, reason: :timeout}} after timeout_ms elapses" do
      # Use a very short timeout (100ms) to keep the test fast
      params = %{question: "Should I proceed?", timeout: 0}

      assert {:ok, result} = RequestApproval.run(params, @context)
      assert result.status == :denied
      assert result.reason == :timeout
      assert result.context == nil
      assert String.contains?(result.message, "timed out")
    end

    test "denied response returns {:ok, %{status: :denied}} with reason and context" do
      params = %{question: "Proceed?"}

      task =
        Task.async(fn ->
          RequestApproval.run(params, @context)
        end)

      Process.sleep(50)

      gate_keys = Registry.keys(Loomkin.Teams.AgentRegistry, task.pid)
      assert [{:approval_gate, gate_id}] = gate_keys

      send(task.pid, {
        :approval_response,
        gate_id,
        %{outcome: :denied, reason: "Not safe yet", context: nil}
      })

      assert {:ok, result} = Task.await(task, 1000)
      assert result.status == :denied
      assert result.reason == :denied
      assert result.message == "Not safe yet"
    end
  end

  describe "registry lifecycle" do
    test "registry unregistered after approval response received" do
      params = %{question: "Clean up after approval?"}

      task =
        Task.async(fn ->
          RequestApproval.run(params, @context)
        end)

      Process.sleep(50)

      gate_keys = Registry.keys(Loomkin.Teams.AgentRegistry, task.pid)
      assert [{:approval_gate, gate_id}] = gate_keys

      send(task.pid, {:approval_response, gate_id, %{outcome: :approved, context: nil}})
      {:ok, _} = Task.await(task, 1000)

      # Registry entry should be gone
      remaining = Registry.keys(Loomkin.Teams.AgentRegistry, task.pid)
      assert remaining == []
    end

    test "registry unregistered after timeout" do
      params = %{question: "Will this timeout?", timeout: 0}

      task = Task.async(fn -> RequestApproval.run(params, @context) end)
      {:ok, _} = Task.await(task, 1000)

      remaining = Registry.keys(Loomkin.Teams.AgentRegistry, task.pid)
      assert remaining == []
    end
  end

  describe "signal structs" do
    test "Approval.Requested can be created with new!/1" do
      signal =
        Approval.Requested.new!(%{
          gate_id: "gate-abc",
          agent_name: "agent-alpha",
          team_id: "team-001",
          question: "Deploy now?"
        })

      assert signal.type == "agent.approval.requested"
      assert signal.data.gate_id == "gate-abc"
    end

    test "Approval.Resolved can be created with new!/1" do
      signal =
        Approval.Resolved.new!(%{
          gate_id: "gate-abc",
          agent_name: "agent-alpha",
          team_id: "team-001",
          outcome: :approved
        })

      assert signal.type == "agent.approval.resolved"
      assert signal.data.outcome == :approved
    end
  end
end
