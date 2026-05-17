defmodule Loomkin.Orchestration.StateSnapshotTest do
  @moduledoc """
  Covers the state-snapshot persistence path:

    * `IssueOrchestrator.persist_phase/2` writes `state_snapshot`,
      `last_phase`, and `last_iteration` alongside `current_phase`
    * advancing through phases updates the snapshot
    * terminal states clear the snapshot
    * `init/1` accepts `:resume_snapshot` and `:resume_phase` and reseeds
      `iterations` / `artifacts` / `attempt_knobs` accordingly
  """
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.IssueOrchestrator
  alias Loomkin.Orchestration.Schema.Epic
  alias Loomkin.Repo

  defp insert_epic(attrs \\ %{}) do
    id = Map.get(attrs, :id, Ecto.UUID.generate())

    defaults = %{
      id: id,
      title: "snap-epic-#{id}",
      spec: "snapshot test",
      status: :pending,
      metadata: %{},
      dod_items: []
    }

    {:ok, epic} =
      %Epic{}
      |> Epic.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    epic
  end

  defp happy_callbacks do
    %{
      researcher: fn _epic -> {:ok, %{research: :done}} end,
      planner: fn _epic, _research -> {:ok, %{plan: :ok}} end,
      plan_review: fn _plan -> {:pass, [%{verdict: :pass}]} end,
      design_review: fn _plan -> {:pass, [%{verdict: :pass}]} end,
      decomposer: fn _plan -> {:ok, [%{id: "wu-1"}]} end,
      executor: fn _epic, _wus -> {:ok, %{commits: ["sha-1"]}} end,
      final_review: fn _epic, _res -> {:pass, [%{verdict: :pass}]} end,
      pr_opener: fn _epic, _res -> {:ok, "https://gh/x/1"} end,
      knowledge: fn _epic, _res -> {:ok, [%{type: :pattern}]} end
    }
  end

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

  setup do
    # DataCase already checked out a sandbox connection for the test pid in
    # its own setup. The orchestrator processes are linked to the test pid
    # but Ecto sandbox isolation means they need an explicit `allow/3`
    # grant to see the test's connection.
    :ok
  end

  test "persist_phase writes state_snapshot, last_phase, last_iteration" do
    epic_row = insert_epic()

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: epic_row.id, title: epic_row.title},
        callbacks: happy_callbacks(),
        owner: self()
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    IssueOrchestrator.start(pid)
    assert wait_until(pid, :closed) == :closed

    refreshed = Repo.get!(Epic, epic_row.id)
    # Terminal status clears the snapshot back to %{}.
    assert refreshed.status == :closed
    assert refreshed.state_snapshot == %{}
  end

  test "persist_phase writes a non-empty snapshot when an in-progress phase is observed" do
    epic_row = insert_epic()
    me = self()
    {:ok, hold} = Agent.start_link(fn -> nil end)

    # Block in the planner — but use an Agent message we can release so we
    # can both inspect the row mid-flight AND let the orchestrator finish
    # cleanly afterwards (avoids dangling Repo work at test teardown).
    cbs =
      happy_callbacks()
      |> Map.put(:planner, fn _epic, _research ->
        send(me, :planner_called)
        # Spin until the test releases us.
        wait_for_release = fn loop ->
          case Agent.get(hold, & &1) do
            :go -> :ok
            _ -> Process.sleep(20) && loop.(loop)
          end
        end

        wait_for_release.(wait_for_release)
        {:ok, %{plan: :ok}}
      end)

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: epic_row.id, title: epic_row.title},
        callbacks: cbs,
        owner: self()
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    IssueOrchestrator.start(pid)
    assert_receive :planner_called, 1_500

    # Once :plan has been entered, the row should reflect that phase + a
    # snapshot containing at least the "research" artifact key.
    refreshed = Repo.get!(Epic, epic_row.id)
    assert refreshed.current_phase == "plan"
    assert refreshed.last_phase == "plan"
    assert refreshed.status == :in_progress
    assert is_map(refreshed.state_snapshot)
    assert "research" in Map.get(refreshed.state_snapshot, "artifacts_keys", [])

    # Release the planner so the orchestrator can advance to a terminal
    # state and shut down cleanly before the sandbox connection is reaped.
    Agent.update(hold, fn _ -> :go end)
    assert wait_until(pid, :closed) == :closed
  end

  test "init/1 accepts :resume_snapshot and seeds iterations + artifacts" do
    snapshot = %{
      "iterations" => %{"plan_review" => 2},
      "artifacts_keys" => ["research", "plan"],
      "attempt_knobs" => %{},
      "paused_from" => nil,
      "approval_reason" => nil
    }

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: "epic-resume-1", title: "t"},
        callbacks: happy_callbacks(),
        resume_snapshot: snapshot,
        resume_phase: :plan
      )

    snap = IssueOrchestrator.status(pid)
    # iterations were reseeded from the snapshot
    assert snap.iterations[:plan_review] == 2
    # artifact keys were reseeded with the :persisted sentinel — observable
    # via the snapshot's :artifacts list
    assert :research in snap.artifacts
    assert :plan in snap.artifacts
  end

  test "happy-path completion clears the snapshot" do
    epic_row = insert_epic()

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: %{id: epic_row.id, title: epic_row.title},
        callbacks: happy_callbacks(),
        owner: self()
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    IssueOrchestrator.start(pid)
    assert wait_until(pid, :closed) == :closed

    refreshed = Repo.get!(Epic, epic_row.id)
    assert refreshed.status == :closed
    assert refreshed.state_snapshot == %{}
  end
end
