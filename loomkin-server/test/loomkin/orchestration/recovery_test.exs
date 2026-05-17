defmodule Loomkin.Orchestration.RecoveryTest do
  @moduledoc """
  Covers `Loomkin.Orchestration.Recovery.sweep/0`:

    * inserts an `:in_progress` epic row directly into the DB, asserts the
      sweep re-spawns its orchestrator into `EpicRegistry`
    * verifies idempotency — calling sweep twice (or with an orchestrator
      already registered) does NOT double-spawn

  Uses `Loomkin.DataCase` for the sandbox + shared connection so the
  background Recovery sweep (which runs on the orchestration supervisor's
  own pid) can see the rows we insert.
  """
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.Recovery
  alias Loomkin.Orchestration.Schema.Epic
  alias Loomkin.Repo

  setup do
    # Sweep runs on the Recovery process (started by the supervision tree);
    # share our sandbox connection with it so it can see the rows we insert.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Snapshot any orchestrators alive at test start so we can ignore them
    # when asserting "this epic is now registered".
    on_exit(fn ->
      # Best-effort cleanup: stop any orchestrators we left behind so the
      # next test starts clean.
      for {_id, pid, _, _} <- Loomkin.Orchestration.EpicSupervisor.list_active() do
        if Process.alive?(pid),
          do:
            DynamicSupervisor.terminate_child(
              Loomkin.Orchestration.EpicSupervisor,
              pid
            )
      end
    end)

    :ok
  end

  defp insert_in_progress_epic(attrs \\ %{}) do
    id = Ecto.UUID.generate()

    defaults = %{
      id: id,
      title: "Recoverable epic #{id}",
      spec: "Resume me",
      status: :in_progress,
      current_phase: "plan",
      last_phase: "plan",
      last_iteration: 0,
      state_snapshot: %{
        "iterations" => %{"plan_review" => 1},
        "artifacts_keys" => ["research", "plan"]
      },
      metadata: %{},
      dod_items: []
    }

    attrs = Map.merge(defaults, attrs)

    {:ok, epic} =
      %Epic{}
      |> Epic.changeset(attrs)
      |> Repo.insert()

    epic
  end

  test "sweep re-spawns orchestrators for :in_progress epics not currently running" do
    epic = insert_in_progress_epic()

    # Confirm no orchestrator is alive yet for this epic.
    assert Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id) == []

    :ok = Recovery.sweep()

    # The submit path is synchronous, so by the time sweep returns the
    # process should be registered.
    assert [{pid, _}] = Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "sweep is idempotent — already-running orchestrators are skipped" do
    epic = insert_in_progress_epic()

    :ok = Recovery.sweep()
    assert [{pid1, _}] = Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id)

    # Second sweep should find the orchestrator already alive and no-op.
    :ok = Recovery.sweep()
    assert [{pid2, _}] = Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id)

    assert pid1 == pid2, "expected the same pid; got a re-spawn"
  end

  test "sweep also picks up :awaiting_human epics" do
    epic =
      insert_in_progress_epic(%{
        status: :awaiting_human,
        last_phase: "escalated"
      })

    assert Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id) == []

    :ok = Recovery.sweep()

    assert [{pid, _}] = Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id)
    assert Process.alive?(pid)
  end

  test "sweep ignores :pending / :closed / :failed / :cancelled epics" do
    for status <- [:pending, :closed, :failed, :cancelled] do
      epic =
        insert_in_progress_epic(%{
          id: Ecto.UUID.generate(),
          status: status
        })

      :ok = Recovery.sweep()

      assert Registry.lookup(Loomkin.Orchestration.EpicRegistry, epic.id) == [],
             "expected no orchestrator for #{status} epic, but one was spawned"
    end
  end
end
