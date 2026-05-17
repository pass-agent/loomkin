defmodule Loomkin.Orchestration.Executor do
  @moduledoc """
  Drives all the work units of an epic through `WorkUnitPipeline`s.

  Called from `IssueOrchestrator.execute` (the 6th phase). For each work
  unit (in topological order of `deps`), spawns a pipeline, waits for it
  to reach `:done` or `:failed`, and collects the results.

  The Executor is *not* a GenServer — it runs synchronously inside the
  IssueOrchestrator process so that gate-iteration semantics still apply.
  Pipelines themselves are children of the dedicated
  `WorkUnitSupervisor` for clean teardown.

  Public entry point: `run/3` returns `{:ok, results}` where `results` is
  a map keyed by work unit id with `:commit_sha`, `:verdicts`, `:status`.
  """

  alias Loomkin.Orchestration.{WorkUnitPipeline, WorkUnitSupervisor}

  @timeout :timer.minutes(10)

  @doc """
  Runs the work units. Options:

    * `:work_unit_supervisor` — `WorkUnitSupervisor` pid or name. If absent
      a one-shot supervisor is started just for this run.
    * `:callbacks` — same shape as `WorkUnitPipeline` callbacks
    * `:max_iterations` — passed through to each pipeline
    * `:timeout` — overall per-unit deadline
  """
  @spec run(map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(epic, work_units, opts \\ []) when is_list(work_units) do
    callbacks = Keyword.fetch!(opts, :callbacks)
    timeout = Keyword.get(opts, :timeout, @timeout)
    max_iter = Keyword.get(opts, :max_iterations)
    worktree_path = Keyword.get(opts, :worktree_path)

    {sup, started_here?} = ensure_supervisor(opts)

    try do
      run_topological(epic, work_units, callbacks, sup, max_iter, timeout, worktree_path)
    after
      if started_here?, do: Supervisor.stop(sup)
    end
  end

  defp ensure_supervisor(opts) do
    case Keyword.get(opts, :work_unit_supervisor) do
      nil ->
        {:ok, pid} = WorkUnitSupervisor.start_link([])
        {pid, true}

      sup ->
        {sup, false}
    end
  end

  defp run_topological(epic, work_units, callbacks, sup, max_iter, timeout, worktree_path) do
    ordered = topo_sort(work_units)

    Enum.reduce_while(ordered, {:ok, %{}}, fn wu, {:ok, acc} ->
      case run_one(epic, wu, callbacks, sup, max_iter, timeout, worktree_path) do
        {:done, result} ->
          {:cont, {:ok, Map.put(acc, wu_id(wu), result)}}

        {:failed, reason} ->
          {:halt, {:error, {:work_unit_failed, wu_id(wu), reason}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_one(_epic, wu, callbacks, sup, max_iter, timeout, worktree_path) do
    wu_with_worktree = maybe_attach_worktree(wu, worktree_path)

    opts =
      [
        work_unit: wu_with_worktree,
        callbacks: callbacks,
        owner: self()
      ]
      |> add_optional(:max_iterations, max_iter)

    {:ok, pid} = WorkUnitSupervisor.start_pipeline(sup, opts)
    WorkUnitPipeline.start(pid)

    receive do
      {:work_unit_pipeline, ^pid, :completed} ->
        {_state, data} = WorkUnitPipeline.status(pid)

        {:done,
         %{
           status: :done,
           commit_sha: data.commit_sha,
           verdicts: data.verdicts
         }}

      {:work_unit_pipeline, ^pid, :failed} ->
        {_state, data} = WorkUnitPipeline.status(pid)
        {:failed, %{verdicts: data.verdicts}}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp add_optional(opts, _key, nil), do: opts
  defp add_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_attach_worktree(wu, nil), do: wu

  defp maybe_attach_worktree(wu, path) when is_map(wu) and is_binary(path) do
    Map.put(wu, :worktree_path, path)
  end

  defp wu_id(wu) when is_map(wu), do: Map.get(wu, :id) || Map.get(wu, "id")

  defp topo_sort(work_units) do
    # Simple Kahn's algorithm tolerant of missing deps (treats unknown deps as :ok).
    by_id = Map.new(work_units, &{wu_id(&1), &1})

    {sorted, remaining} =
      Enum.split_with(work_units, fn wu -> Map.get(wu, :deps, []) == [] end)

    sorted ++ kahn_loop(remaining, MapSet.new(Enum.map(sorted, &wu_id/1)), by_id)
  end

  defp kahn_loop([], _ready, _by_id), do: []

  defp kahn_loop(remaining, ready, by_id) do
    {ok, still} =
      Enum.split_with(remaining, fn wu ->
        Enum.all?(Map.get(wu, :deps, []), fn d -> MapSet.member?(ready, d) end)
      end)

    case ok do
      [] ->
        # Cyclic or missing deps; append remaining in original order to avoid hang.
        remaining

      _ ->
        ok ++ kahn_loop(still, Enum.reduce(ok, ready, &MapSet.put(&2, wu_id(&1))), by_id)
    end
  end
end
