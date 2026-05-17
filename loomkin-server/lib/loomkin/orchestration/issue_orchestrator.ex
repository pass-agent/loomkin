defmodule Loomkin.Orchestration.IssueOrchestrator do
  @moduledoc """
  `:gen_statem` for a single epic.

  States (canonical 9-phase order from `Loomkin.Orchestration.phases/0`):

      :research → :plan → :plan_review → :design_review →
      :decompose → :execute → :final_review → :pr → :closure

  Plus terminal states `:closed` (success) and `:escalated` (3-iteration cap
  exceeded; awaits a human resume).

  Each phase has a single named state. Transitions require either:

    * a callback that returns `{:ok, artifact}`, or
    * a gate callback that returns `{:pass | :fail, [verdict]}`.

  Gates are subject to `max_gate_iterations` retries. The 4th attempt emits
  `orchestration.epic.escalated` on the bus and stops the state machine in
  `:escalated`.

  Callbacks (injected at start):

      %{
        researcher:      (epic -> {:ok, research_artifact}),
        planner:         (epic, research -> {:ok, plan}),
        plan_review:     (plan -> {:pass | :fail, verdicts}),
        design_review:   (plan -> {:pass | :fail, verdicts}),
        decomposer:      (plan -> {:ok, [work_unit]}),
        executor:        (epic, [work_unit] -> {:ok, results} | {:error, _}),
        final_review:    (epic, results -> {:pass | :fail, verdicts}),
        pr_opener:       (epic, results -> {:ok, pr_url} | {:error, _}),
        knowledge:       (epic, results -> {:ok, [fact]})
      }
  """
  @behaviour :gen_statem

  alias Loomkin.Orchestration
  alias Loomkin.Orchestration.RetryLadder

  defstruct [
    :epic,
    :callbacks,
    :max_iterations,
    :owner,
    :bus_topic,
    :artifacts,
    :iterations,
    :gate_verdicts,
    :attempt_knobs,
    :worktree_pid
  ]

  @type data :: %__MODULE__{
          epic: map(),
          callbacks: map(),
          max_iterations: pos_integer(),
          owner: pid() | nil,
          bus_topic: String.t(),
          artifacts: map(),
          iterations: map(),
          gate_verdicts: map(),
          attempt_knobs: %{optional(atom()) => RetryLadder.knobs() | :escalate},
          worktree_pid: pid() | nil
        }

  ## Client API

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  def start(server), do: :gen_statem.cast(server, :start)
  def resume(server), do: :gen_statem.cast(server, :resume)
  def status(server), do: :gen_statem.call(server, :status)

  ## :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    data = %__MODULE__{
      epic: Keyword.fetch!(opts, :epic),
      callbacks: Keyword.fetch!(opts, :callbacks),
      max_iterations: Keyword.get(opts, :max_iterations, Orchestration.max_gate_iterations()),
      owner: Keyword.get(opts, :owner),
      bus_topic: Keyword.get(opts, :bus_topic, "orchestration.epic"),
      artifacts: %{},
      iterations: %{},
      gate_verdicts: %{},
      attempt_knobs: %{},
      worktree_pid: nil
    }

    {:ok, :pending, data}
  end

  ## :pending — awaits :start

  def pending(:enter, _old, _data), do: :keep_state_and_data

  def pending(:cast, :start, data) do
    broadcast(data, :created)
    {:next_state, :research, data}
  end

  def pending({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(:pending, data)}]}

  ## Generic helpers below define each named phase as a state function

  for phase <- [:plan, :decompose, :execute, :pr, :closure] do
    def unquote(phase)(:enter, _old, data) do
      data = enter_phase(data, unquote(phase))
      {:keep_state, data, [{:state_timeout, 0, :run}]}
    end

    def unquote(phase)({:call, from}, :status, data),
      do: {:keep_state_and_data, [{:reply, from, snapshot(unquote(phase), data)}]}
  end

  ## :research has a custom enter that boots the per-epic Worktree.
  def research(:enter, _old, data) do
    data =
      data
      |> enter_phase(:research)
      |> maybe_start_worktree()

    {:keep_state, data, [{:state_timeout, 0, :run}]}
  end

  def research({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(:research, data)}]}

  for phase <- [:plan_review, :design_review, :final_review] do
    def unquote(phase)(:enter, _old, data) do
      data = enter_phase(data, unquote(phase))
      {:keep_state, data, [{:state_timeout, 0, :run_gate}]}
    end

    def unquote(phase)({:call, from}, :status, data),
      do: {:keep_state_and_data, [{:reply, from, snapshot(unquote(phase), data)}]}
  end

  ## :research

  def research(:state_timeout, :run, data) do
    case call_cb(data.callbacks[:researcher], [data.epic]) do
      {:ok, artifact} ->
        data = stash(data, :research, artifact)
        {:next_state, :plan, data}

      {:error, reason} ->
        fail(data, :research, reason)
    end
  end

  ## :plan

  def plan(:state_timeout, :run, data) do
    research = data.artifacts[:research]

    case call_cb(data.callbacks[:planner], [data.epic, research]) do
      {:ok, plan} ->
        data = stash(data, :plan, plan)
        {:next_state, :plan_review, data}

      {:error, reason} ->
        fail(data, :plan, reason)
    end
  end

  ## :plan_review (gate)

  def plan_review(:state_timeout, :run_gate, data) do
    run_gate(:plan_review, data, [data.artifacts[:plan]], :plan, :design_review)
  end

  ## :design_review (gate)

  def design_review(:state_timeout, :run_gate, data) do
    run_gate(:design_review, data, [data.artifacts[:plan]], :plan, :decompose)
  end

  ## :decompose

  def decompose(:state_timeout, :run, data) do
    case call_cb(data.callbacks[:decomposer], [data.artifacts[:plan]]) do
      {:ok, work_units} ->
        data = stash(data, :work_units, work_units)
        {:next_state, :execute, data}

      {:error, reason} ->
        fail(data, :decompose, reason)
    end
  end

  ## :execute

  def execute(:state_timeout, :run, data) do
    epic_with_artifacts = enrich_epic_for_executor(data)

    case call_cb(data.callbacks[:executor], [epic_with_artifacts, data.artifacts[:work_units]]) do
      {:ok, results} ->
        data = stash(data, :execution, results)
        {:next_state, :final_review, data}

      {:error, reason} ->
        fail(data, :execute, reason)
    end
  end

  # Hand the executor a view of the epic that includes the worktree path so the
  # default callbacks (which only get `epic`) can forward it into work-unit
  # payloads. The shape mirrors what `Loomkin.Orchestration.Callbacks.epic_worktree_path/1`
  # reads.
  defp enrich_epic_for_executor(%{epic: epic, artifacts: artifacts}) when is_map(epic) do
    case artifacts[:worktree_path] do
      nil ->
        epic

      path when is_binary(path) ->
        existing = Map.get(epic, :artifacts, %{})
        Map.put(epic, :artifacts, Map.put(existing, :worktree_path, path))
    end
  end

  ## :final_review (gate)

  def final_review(:state_timeout, :run_gate, data) do
    run_gate(:final_review, data, [data.epic, data.artifacts[:execution]], :execute, :pr)
  end

  ## :pr

  def pr(:state_timeout, :run, data) do
    case call_cb(data.callbacks[:pr_opener], [data.epic, data.artifacts[:execution]]) do
      {:ok, pr_url} ->
        data = stash(data, :pr_url, pr_url)
        {:next_state, :closure, data}

      {:error, reason} ->
        fail(data, :pr, reason)
    end
  end

  ## :closure

  def closure(:state_timeout, :run, data) do
    case call_cb(data.callbacks[:knowledge], [data.epic, data.artifacts[:execution]]) do
      {:ok, facts} ->
        data = stash(data, :facts, facts)
        {:next_state, :closed, data}

      {:error, reason} ->
        fail(data, :closure, reason)
    end
  end

  ## Terminal states

  def closed(:enter, _old, data) do
    data = stop_worktree(data)
    broadcast(data, :closed)
    persist_terminal(data, :closed)
    notify_owner(data, :closed)
    {:keep_state, data}
  end

  def closed({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(:closed, data)}]}

  def escalated(:enter, _old, data) do
    data = stop_worktree(data)
    broadcast(data, {:escalated, data.iterations})
    persist_terminal(data, :awaiting_human)
    emit_escalated_telemetry(data)
    notify_owner(data, :escalated)
    {:keep_state, data}
  end

  def escalated(:cast, :resume, _data) do
    # Human said "go" — placeholder: in v1 resume is a logged no-op so the
    # process stays parked for human attention. A future iteration will
    # rewind to the previous gate and re-run with cleared iteration counters.
    :keep_state_and_data
  end

  def escalated({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(:escalated, data)}]}

  def failed(:enter, _old, data) do
    data = stop_worktree(data)
    broadcast(data, :failed)
    persist_terminal(data, :failed)
    notify_owner(data, :failed)
    {:keep_state, data}
  end

  def failed({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(:failed, data)}]}

  ## Internals

  defp call_cb(fun, args) when is_function(fun) and is_list(args), do: apply(fun, args)
  defp call_cb({mod, fun}, args), do: apply(mod, fun, args)
  defp call_cb(nil, _), do: {:error, :no_callback}

  defp stash(data, key, value) do
    %{data | artifacts: Map.put(data.artifacts, key, value)}
  end

  defp enter_phase(data, phase) do
    broadcast(data, {:phase_entered, phase})
    persist_phase(data, phase)
    emit_phase_telemetry(data, phase)
    data
  end

  defp emit_phase_telemetry(%{epic: epic} = data, phase) do
    epic_id = Map.get(epic, :id) || Map.get(epic, "id")

    :telemetry.execute(
      [:loomkin, :orchestration, :epic, :phase_entered],
      %{},
      %{
        epic_id: epic_id,
        phase: phase,
        attempt_knobs: Map.get(data.attempt_knobs, phase)
      }
    )
  rescue
    _ -> :ok
  end

  defp persist_phase(%{epic: %{id: id}}, phase) when is_binary(id) do
    # Best-effort: update Epic.current_phase. If the epic isn't in the DB
    # (e.g. unit-test fixtures) we silently no-op.
    try do
      case Loomkin.Repo.get(Loomkin.Orchestration.Schema.Epic, id) do
        nil ->
          :ok

        epic ->
          epic
          |> Ecto.Changeset.change(%{
            current_phase: Atom.to_string(phase),
            status: phase_to_status(phase)
          })
          |> Loomkin.Repo.update()
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp persist_phase(_, _), do: :ok

  defp phase_to_status(:closure), do: :in_progress
  defp phase_to_status(_), do: :in_progress

  defp persist_terminal(%{epic: %{id: id}}, status) when is_binary(id) do
    try do
      case Loomkin.Repo.get(Loomkin.Orchestration.Schema.Epic, id) do
        nil ->
          :ok

        epic ->
          epic
          |> Ecto.Changeset.change(%{status: status})
          |> Loomkin.Repo.update()
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp persist_terminal(_, _), do: :ok

  defp emit_gate_telemetry(%{epic: epic}, phase, verdict, iter, duration_ms, knobs) do
    epic_id = Map.get(epic, :id) || Map.get(epic, "id")

    :telemetry.execute(
      [:loomkin, :orchestration, :gate, :verdict],
      %{duration_ms: duration_ms},
      %{
        epic_id: epic_id,
        gate: phase,
        verdict: verdict,
        iteration: iter,
        model: knob_model(knobs)
      }
    )
  rescue
    _ -> :ok
  end

  defp knob_model(knobs) when is_map(knobs), do: Map.get(knobs, :model)
  defp knob_model(_), do: nil

  defp emit_escalated_telemetry(%{epic: epic, iterations: iterations}) do
    epic_id = Map.get(epic, :id) || Map.get(epic, "id")

    :telemetry.execute(
      [:loomkin, :orchestration, :epic, :escalated],
      %{},
      %{epic_id: epic_id, iterations: iterations}
    )
  rescue
    _ -> :ok
  end

  defp run_gate(phase, data, args, retry_state, next_state) do
    iter = Map.get(data.iterations, phase, 0) + 1
    knobs = RetryLadder.knobs(:gate, iter)

    data = %{
      data
      | iterations: Map.put(data.iterations, phase, iter),
        attempt_knobs: Map.put(data.attempt_knobs, phase, knobs)
    }

    started_at = System.monotonic_time(:millisecond)
    result = call_cb(data.callbacks[phase], args)
    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

    case result do
      {:pass, verdicts} ->
        data = %{data | gate_verdicts: Map.put(data.gate_verdicts, phase, verdicts)}
        broadcast(data, {:gate_verdict, phase, :pass, length(verdicts)})
        emit_gate_telemetry(data, phase, :pass, iter, duration_ms, knobs)
        {:next_state, next_state, data}

      {:fail, verdicts} ->
        data = %{data | gate_verdicts: Map.put(data.gate_verdicts, phase, verdicts)}
        broadcast(data, {:gate_verdict, phase, :fail, length(verdicts)})
        emit_gate_telemetry(data, phase, :fail, iter, duration_ms, knobs)

        if iter >= data.max_iterations do
          {:next_state, :escalated, data}
        else
          {:next_state, retry_state, data}
        end
    end
  end

  defp fail(data, where, reason) do
    broadcast(data, {:fail, where, reason})
    {:next_state, :failed, data}
  end

  defp broadcast(%{bus_topic: topic, epic: epic}, message) when is_binary(topic) do
    payload = %{epic_id: Map.get(epic, :id) || Map.get(epic, "id"), event: message}

    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {topic, payload})
    end
  rescue
    _ -> :ok
  end

  defp broadcast(_, _), do: :ok

  defp notify_owner(%{owner: pid}, msg) when is_pid(pid) do
    send(pid, {:issue_orchestrator, self(), msg})
  end

  defp notify_owner(_, _), do: :ok

  defp snapshot(state, data) do
    %{
      state: state,
      iterations: data.iterations,
      artifacts: Map.keys(data.artifacts),
      gate_verdicts: summarize_verdicts(data.gate_verdicts)
    }
  end

  defp summarize_verdicts(gate_verdicts) do
    Map.new(gate_verdicts, fn {phase, verdicts} -> {phase, length(verdicts)} end)
  end

  ## ─── Worktree wiring ─────────────────────────────────────────────────────

  # Boots a `Worktree` GenServer for this epic and stashes its path into
  # `data.artifacts[:worktree_path]`. Defaults to `dry_run: true` if no
  # `project_path` is available so tests that don't provide one keep working.
  defp maybe_start_worktree(%{worktree_pid: pid} = data) when is_pid(pid), do: data

  defp maybe_start_worktree(%{epic: epic} = data) do
    opts = worktree_opts_for(epic)

    case Loomkin.Orchestration.Worktree.start_link(opts) do
      {:ok, pid} ->
        # Only expose the path to downstream phases when the worktree is real.
        # A dry-run worktree owns the GenServer lifecycle but has no on-disk dir,
        # so injecting its path would mislead the default git committer.
        data =
          if Keyword.get(opts, :dry_run, false) do
            data
          else
            stash(data, :worktree_path, Keyword.fetch!(opts, :path))
          end

        Map.put(data, :worktree_pid, pid)

      {:error, reason} ->
        broadcast(data, {:worktree_start_failed, reason})
        data
    end
  end

  defp worktree_opts_for(epic) when is_map(epic) do
    epic_id =
      Map.get(epic, :id) || Map.get(epic, "id") ||
        "no-id-#{System.unique_integer([:positive])}"

    branch = "orchestration/epic-#{epic_id}"
    metadata = Map.get(epic, :metadata) || Map.get(epic, "metadata") || %{}

    project_path =
      Map.get(metadata, :project_path) || Map.get(metadata, "project_path")

    explicit_worktree =
      Map.get(metadata, :worktree_path) || Map.get(metadata, "worktree_path")

    base_branch =
      Map.get(metadata, :base_branch) || Map.get(metadata, "base_branch") || "main"

    cond do
      is_binary(explicit_worktree) and is_binary(project_path) ->
        [
          repo_path: project_path,
          path: explicit_worktree,
          branch: branch,
          base_branch: base_branch,
          dry_run: Map.get(metadata, :dry_run) || Map.get(metadata, "dry_run") || false
        ]

      is_binary(project_path) ->
        worktree_root =
          Map.get(metadata, :worktree_root) || Map.get(metadata, "worktree_root") ||
            default_worktree_root()

        [
          repo_path: project_path,
          path: Path.join(worktree_root, "epic-#{epic_id}"),
          branch: branch,
          base_branch: base_branch,
          dry_run: Map.get(metadata, :dry_run) || Map.get(metadata, "dry_run") || false
        ]

      true ->
        # No project_path — fall back to a dry-run worktree so the GenServer
        # still owns the lifecycle but nothing touches git.
        [
          repo_path: "/dev/null",
          path: Path.join(System.tmp_dir!(), "loomkin-orch-dryrun-epic-#{epic_id}"),
          branch: branch,
          base_branch: base_branch,
          dry_run: true
        ]
    end
  end

  defp default_worktree_root do
    System.get_env("LOOMKIN_WORKTREE_ROOT") ||
      Path.join(System.tmp_dir!(), "loomkin-orchestration-worktrees")
  end

  defp stop_worktree(%{worktree_pid: pid} = data) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    %{data | worktree_pid: nil}
  rescue
    _ -> %{data | worktree_pid: nil}
  catch
    _, _ -> %{data | worktree_pid: nil}
  end

  defp stop_worktree(data), do: data
end
