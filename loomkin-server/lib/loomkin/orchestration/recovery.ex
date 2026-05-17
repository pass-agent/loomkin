defmodule Loomkin.Orchestration.Recovery do
  @moduledoc """
  On Application.start (via the orchestration `Supervisor`), re-spawns any
  Epic whose status is `:in_progress` or `:awaiting_human`. Each resumed
  orchestrator is fed the persisted `state_snapshot` so it can continue
  from the last completed phase without re-running prior phases' workers.

  ## v1 strategy

  We deliberately keep recovery simple: when sweep finds an in-progress
  epic, we re-spawn its `IssueOrchestrator` and let it restart from
  `:research`. The benefit is that the **epic row** survives (status,
  history) and the **orchestrator process** gets re-spawned — no more
  orphaned `:in_progress` rows with no process. Re-running phases is
  acceptable because:

    * the LLM stub (and real LLM) give consistent enough output that the
      epic still converges, and
    * each phase's persistence is best-effort idempotent (Epic.current_phase
      is overwritten, work_unit rows are dedup'd by id).

  The downside: prior LLM calls are repeated. Once we have artifact-level
  persistence we can resume at `:last_phase` instead. Until then, the
  in-memory `data.artifacts` map is reseeded with a `:persisted` sentinel
  from `state_snapshot["artifacts_keys"]` so downstream callbacks can detect
  resume (but the v1 default path runs from `:research`).

  ## Idempotency

  If an orchestrator is already alive in `EpicRegistry`, Recovery skips it.
  This avoids double-spawning during hot code reloads or manual restarts.
  """
  use GenServer

  require Logger

  alias Loomkin.Orchestration.Schema.Epic
  alias Loomkin.Orchestration.SwarmCoordinator

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    # Defer the sweep to after init/1 so `Supervisor.init`'s "wait for all
    # children" gate doesn't block on our DB query (and so a Repo crash
    # during recovery doesn't cascade into the whole subsystem).
    {:ok, %{}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    try do
      sweep()
    rescue
      err ->
        Logger.error("Loomkin.Orchestration.Recovery sweep failed: #{Exception.message(err)}")

        :ok
    end

    {:noreply, state}
  end

  @doc """
  Find every epic in a non-terminal status and re-spawn its orchestrator if
  one isn't already alive in `EpicRegistry`. Exposed publicly so tests can
  trigger a sweep without restarting the GenServer.
  """
  @spec sweep() :: :ok
  def sweep do
    import Ecto.Query

    query =
      from e in Epic,
        where: e.status in [:in_progress, :awaiting_human],
        order_by: [asc: e.inserted_at]

    epics =
      try do
        Loomkin.Repo.all(query)
      rescue
        # If the Repo isn't started yet (tests, partial boots) just skip.
        _ -> []
      end

    for epic <- epics do
      maybe_respawn(epic)
    end

    :ok
  end

  defp maybe_respawn(%Epic{id: id} = epic) do
    case Registry.lookup(Loomkin.Orchestration.EpicRegistry, id) do
      [] ->
        Logger.info(
          "Loomkin.Orchestration.Recovery: re-spawning orchestrator for epic #{id} " <>
            "(status=#{epic.status}, last_phase=#{inspect(epic.last_phase)})"
        )

        SwarmCoordinator.submit(
          %{
            id: id,
            title: epic.title,
            spec: epic.spec,
            metadata: epic.metadata || %{}
          },
          resume_snapshot: epic.state_snapshot || %{},
          resume_phase: maybe_atom(epic.last_phase)
        )

      [_pid_tuple] ->
        # Already running — no-op.
        :ok
    end
  rescue
    err ->
      Logger.warning(
        "Loomkin.Orchestration.Recovery: failed to respawn epic #{epic.id}: " <>
          Exception.message(err)
      )

      :ok
  end

  defp maybe_atom(nil), do: nil
  defp maybe_atom(s) when is_atom(s), do: s

  defp maybe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
