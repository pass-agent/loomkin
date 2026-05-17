defmodule Loomkin.Orchestration.IssueOrchestratorTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.IssueOrchestrator

  defp wait_until(server, target, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(server, target, deadline)
  end

  defp do_wait_until(server, target, deadline) do
    %{state: state} = IssueOrchestrator.status(server)

    cond do
      state == target ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out; last state: #{inspect(state)} (target: #{inspect(target)})")

      true ->
        Process.sleep(5)
        do_wait_until(server, target, deadline)
    end
  end

  defp happy_callbacks do
    %{
      researcher: fn _epic -> {:ok, %{research: :done}} end,
      planner: fn _epic, _research -> {:ok, %{plan: :ok}} end,
      plan_review: fn _plan -> {:pass, [%{verdict: :pass}]} end,
      design_review: fn _plan -> {:pass, [%{verdict: :pass}]} end,
      decomposer: fn _plan -> {:ok, [%{id: "wu-1"}, %{id: "wu-2"}]} end,
      executor: fn _epic, _wus -> {:ok, %{commits: ["sha-1", "sha-2"]}} end,
      final_review: fn _epic, _res -> {:pass, [%{verdict: :pass}]} end,
      pr_opener: fn _epic, _res -> {:ok, "https://gh/x/1"} end,
      knowledge: fn _epic, _res -> {:ok, [%{type: :pattern}]} end
    }
  end

  test "happy-path flows through all 9 phases to :closed" do
    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: "epic-1", title: "t"},
        callbacks: happy_callbacks(),
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert wait_until(pid, :closed) == :closed
    assert_receive {:issue_orchestrator, ^pid, :closed}, 1_000
  end

  test "plan_review fail beyond cap escalates" do
    cbs =
      happy_callbacks()
      |> Map.put(:plan_review, fn _ -> {:fail, [%{verdict: :fail}]} end)

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: "epic-2", title: "t"},
        callbacks: cbs,
        max_iterations: 2,
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert wait_until(pid, :escalated) == :escalated
    assert_receive {:issue_orchestrator, ^pid, :escalated}, 1_000

    snapshot = IssueOrchestrator.status(pid)
    assert snapshot.iterations[:plan_review] >= 2
  end

  test "researcher returning :error transitions to :failed" do
    cbs = Map.put(happy_callbacks(), :researcher, fn _ -> {:error, :bad} end)

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: "epic-3", title: "t"},
        callbacks: cbs,
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert wait_until(pid, :failed) == :failed
    assert_receive {:issue_orchestrator, ^pid, :failed}, 1_000
  end
end
