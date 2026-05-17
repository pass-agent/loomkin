defmodule Loomkin.Orchestration.WorkUnitPipeline do
  @moduledoc """
  `:gen_statem` for the 4-phase per-work-unit pipeline.

  States: `:implement → :validate → :adversarial_review → :commit → :done`.

  Trust-nothing principle: the `:validate` state is run by *this* state machine
  via the `validator` callback. It does NOT consult the Coder worker that
  produced the artifact.

  The work unit transitions to `:done` when the commit succeeds, or to
  `:failed` after `Loomkin.Orchestration.max_gate_iterations/0` iterations of
  any single state.

  ## Callbacks

  Callers inject a callbacks map at start:

      %{
        implementer: (work_unit -> {:ok, artifact} | {:error, reason}),
        validator:   (artifact   -> :ok | {:ok, [String.t()]} | {:error, [String.t()]}),
        reviewer:    (artifact   -> {:pass | :fail, [verdict]}),
        committer:   (artifact   -> {:ok, sha} | {:error, reason})
      }

  When the validator returns `{:ok, warnings}` the warnings are stashed on
  `data.validator_diagnostics` and threaded into the reviewer's payload as
  `:validator_diagnostics`, so the adversarial reviewer can cite real
  diagnostics rather than hallucinating them.

  In production these point at `Workers.Coder`, the in-process validator,
  `Gates.AdversarialReviewGate`, and a git committer. In tests they are
  stubs that drive the state machine deterministically.
  """
  @behaviour :gen_statem

  alias Loomkin.Orchestration.Diff
  alias Loomkin.Orchestration.RetryLadder
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  defstruct [
    :work_unit,
    :callbacks,
    :artifact,
    :verdicts,
    :iteration,
    :max_iterations,
    :commit_sha,
    :owner,
    :bus_topic,
    :attempt_knobs,
    :prior_failures,
    :validator_diagnostics
  ]

  @typedoc "Per-pipeline runtime data."
  @type data :: %__MODULE__{
          work_unit: map(),
          callbacks: map(),
          artifact: any() | nil,
          verdicts: [ReviewVerdict.t()],
          iteration: pos_integer(),
          max_iterations: pos_integer(),
          commit_sha: String.t() | nil,
          owner: pid() | nil,
          bus_topic: String.t() | nil,
          attempt_knobs: RetryLadder.knobs() | :escalate | nil,
          prior_failures: [%{iteration: pos_integer(), verdicts: [ReviewVerdict.t()]}],
          validator_diagnostics: [String.t()]
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

  @doc "Kick off the pipeline. Required after start_link/1."
  def start(server), do: :gen_statem.cast(server, :start)

  @doc "Snapshot of the current state and runtime data."
  def status(server), do: :gen_statem.call(server, :status)

  ## gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    data = %__MODULE__{
      work_unit: Keyword.fetch!(opts, :work_unit),
      callbacks: Keyword.fetch!(opts, :callbacks),
      artifact: nil,
      verdicts: [],
      iteration: 1,
      max_iterations: Keyword.get(opts, :max_iterations, max_iterations()),
      commit_sha: nil,
      owner: Keyword.get(opts, :owner),
      bus_topic: Keyword.get(opts, :bus_topic, "orchestration.work_unit"),
      attempt_knobs: RetryLadder.knobs(:work_unit, 1),
      prior_failures: [],
      validator_diagnostics: []
    }

    {:ok, :idle, data}
  end

  defp max_iterations do
    Loomkin.Orchestration.max_gate_iterations()
  end

  ## State callbacks

  def idle(:enter, _old, _data), do: :keep_state_and_data

  def idle(:cast, :start, data) do
    broadcast(data, :started)
    {:next_state, :implement, data}
  end

  def idle({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:idle, data}}]}

  ## :implement

  def implement(:enter, _old, data) do
    {:keep_state, data, [{:state_timeout, 0, :run}]}
  end

  def implement(:state_timeout, :run, data) do
    case call_cb_with_payload(data.callbacks[:implementer], data) do
      {:ok, artifact} ->
        data = %{data | artifact: artifact}
        broadcast(data, :implement_complete)
        {:next_state, :validate, data}

      {:error, reason} ->
        fail(data, :implement, reason)
    end
  end

  def implement({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:implement, data}}]}

  ## :validate (orchestrator runs this independently — trust-nothing)

  def validate(:enter, _old, data) do
    {:keep_state, data, [{:state_timeout, 0, :run}]}
  end

  def validate(:state_timeout, :run, data) do
    case call_cb_with_payload(data.callbacks[:validator], data) do
      :ok ->
        data = %{data | validator_diagnostics: []}
        broadcast(data, :validate_pass)
        {:next_state, :adversarial_review, data}

      {:ok, warnings} when is_list(warnings) ->
        data = %{data | validator_diagnostics: warnings}
        broadcast(data, {:validate_pass, warnings})
        {:next_state, :adversarial_review, data}

      {:error, problems} ->
        broadcast(data, {:validate_fail, problems})
        maybe_retry(data, :implement, problems)
    end
  end

  def validate({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:validate, data}}]}

  ## :adversarial_review

  def adversarial_review(:enter, _old, data) do
    {:keep_state, data, [{:state_timeout, 0, :run}]}
  end

  def adversarial_review(:state_timeout, :run, data) do
    case call_cb_with_payload(data.callbacks[:reviewer], data) do
      {:pass, verdicts} ->
        data = %{data | verdicts: verdicts}
        broadcast(data, {:review_pass, verdicts})
        {:next_state, :commit, data}

      {:fail, verdicts} ->
        data = %{data | verdicts: verdicts}
        broadcast(data, {:review_fail, verdicts})
        maybe_retry(data, :implement, verdicts)
    end
  end

  def adversarial_review({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:adversarial_review, data}}]}

  ## :commit

  def commit(:enter, _old, data) do
    {:keep_state, data, [{:state_timeout, 0, :run}]}
  end

  def commit(:state_timeout, :run, data) do
    case call_cb_with_payload(data.callbacks[:committer], data) do
      {:ok, sha} ->
        data = %{data | commit_sha: sha}
        broadcast(data, {:commit_done, sha})
        maybe_broadcast_diff(data, sha)
        {:next_state, :done, data}

      {:error, reason} ->
        fail(data, :commit, reason)
    end
  end

  def commit({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:commit, data}}]}

  ## :done

  def done(:enter, _old, data) do
    broadcast(data, :completed)
    emit_work_unit_telemetry(data, :completed)
    notify_owner(data, :completed)
    :keep_state_and_data
  end

  def done({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:done, data}}]}

  ## :failed

  def failed(:enter, _old, data) do
    broadcast(data, :failed)
    emit_work_unit_telemetry(data, :failed)
    notify_owner(data, :failed)
    :keep_state_and_data
  end

  def failed({:call, from}, :status, data),
    do: {:keep_state_and_data, [{:reply, from, {:failed, data}}]}

  ## Telemetry

  defp emit_work_unit_telemetry(%{work_unit: wu}, outcome) do
    work_unit_id = Map.get(wu, :id) || Map.get(wu, "id")
    epic_id = Map.get(wu, :epic_id) || Map.get(wu, "epic_id")

    event =
      case outcome do
        :completed -> [:loomkin, :orchestration, :work_unit, :completed]
        :failed -> [:loomkin, :orchestration, :work_unit, :failed]
      end

    :telemetry.execute(event, %{}, %{work_unit_id: work_unit_id, epic_id: epic_id})
  rescue
    _ -> :ok
  end

  ## Helpers

  # The pipeline ALWAYS builds the payload map, then invokes the callback in a
  # tolerant way:
  #
  #   * `arity-1` funs receive the bare work_unit (backward-compat with the
  #     legacy `(work_unit -> result)` / `(artifact -> result)` contract used
  #     across the existing test fixtures and gates).
  #   * `arity-2` funs receive `(primary_arg, payload)` where `primary_arg`
  #     is the work_unit for the implementer and the artifact for the
  #     downstream callbacks (validator/reviewer/committer). Production
  #     callbacks in `Callbacks` use this richer signature so they can read
  #     `payload.prior_failures`, `payload.attempt_knobs`, etc.
  #   * `{mod, fun, extra_args}` tuples retain the previous semantics —
  #     `apply(mod, fun, [primary_arg | extra_args])` — for callers that
  #     want to bind extra config without closing over it in a closure.
  defp call_cb_with_payload(fun, %__MODULE__{} = data) do
    payload = payload_from(data)
    call_cb(fun, primary_arg(fun, data), payload)
  end

  defp payload_from(%__MODULE__{} = data) do
    %{
      work_unit: data.work_unit,
      artifact: data.artifact,
      prior_failures: data.prior_failures || [],
      attempt_knobs: data.attempt_knobs,
      iteration: data.iteration,
      validator_diagnostics: data.validator_diagnostics || []
    }
  end

  # For the implementer the primary arg is the work_unit; for everything else
  # downstream (validator/reviewer/committer) it is the artifact. We look at
  # the artifact: when it is `nil` we are pre-implement, so the work_unit is
  # the right primary arg.
  defp primary_arg(_fun, %__MODULE__{artifact: nil, work_unit: wu}), do: wu
  defp primary_arg(_fun, %__MODULE__{artifact: artifact}), do: artifact

  defp call_cb(fun, primary, _payload) when is_function(fun, 1), do: fun.(primary)
  defp call_cb(fun, primary, payload) when is_function(fun, 2), do: fun.(primary, payload)

  defp call_cb({mod, fun, extra_args}, primary, _payload)
       when is_atom(mod) and is_atom(fun),
       do: apply(mod, fun, [primary | extra_args])

  defp call_cb(nil, _primary, _payload), do: {:error, :no_callback}

  defp maybe_retry(%{iteration: i, max_iterations: max} = data, _retry_state, reason)
       when i >= max do
    fail(data, :iteration_cap, reason)
  end

  defp maybe_retry(data, retry_state, reason) do
    next_iter = data.iteration + 1
    knobs = RetryLadder.knobs(:work_unit, next_iter)
    data = %{data | iteration: next_iter, attempt_knobs: knobs}
    data = maybe_record_prior_failure(data, retry_state, reason)
    broadcast(data, {:retry, retry_state, reason})
    {:next_state, retry_state, data}
  end

  # When we're about to re-enter `:implement`, snapshot the verdicts that
  # caused the bounce (either adversarial-review verdicts or validator
  # `:error` problems) into `prior_failures` so the next implementer call
  # can see them.
  defp maybe_record_prior_failure(%__MODULE__{} = data, :implement, reason) do
    entry = %{
      iteration: data.iteration - 1,
      verdicts: normalize_failure_reason(reason)
    }

    %{data | prior_failures: (data.prior_failures || []) ++ [entry]}
  end

  defp maybe_record_prior_failure(data, _retry_state, _reason), do: data

  # Adversarial review hands us a list of ReviewVerdict structs already;
  # validator hands us a list of strings. We normalise validator strings
  # into synthetic verdict-shaped maps so downstream prompt renderers can
  # treat them uniformly.
  defp normalize_failure_reason(verdicts) when is_list(verdicts) do
    Enum.map(verdicts, fn
      %ReviewVerdict{} = v ->
        v

      problem when is_binary(problem) ->
        %{
          reviewer: "validator",
          verdict: :fail,
          blocking: [problem],
          evidence: [],
          warnings: [],
          rationale: problem
        }

      other ->
        %{
          reviewer: "unknown",
          verdict: :fail,
          blocking: [inspect(other)],
          evidence: [],
          warnings: [],
          rationale: inspect(other)
        }
    end)
  end

  defp normalize_failure_reason(other), do: normalize_failure_reason([other])

  defp fail(data, where, reason) do
    broadcast(data, {:fail, where, reason})
    {:next_state, :failed, data}
  end

  defp broadcast(%{bus_topic: topic, work_unit: wu}, message) when is_binary(topic) do
    payload = %{work_unit_id: Map.get(wu, :id) || Map.get(wu, "id"), event: message}

    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {topic, payload})
    end
  rescue
    _ -> :ok
  end

  defp broadcast(_, _), do: :ok

  # Capture a diff for the just-landed sha and broadcast it on the same
  # `orchestration.work_unit` topic so SignalBridge can re-publish it as a
  # `session.orchestration.diff` Jido.Signal.
  #
  # We use a flat payload (event tag `:diff`) so the bridge can distinguish
  # diff events from regular phase events.
  defp maybe_broadcast_diff(%{artifact: artifact, work_unit: wu, bus_topic: topic} = data, sha)
       when is_binary(topic) do
    case worktree_from_artifact(artifact) do
      nil ->
        :ok

      worktree when is_binary(worktree) ->
        case Diff.capture(sha, worktree) do
          {:ok, capture} ->
            payload = %{
              work_unit_id: Map.get(wu, :id) || Map.get(wu, "id"),
              event: :diff,
              sha: capture.sha,
              stats: capture.stats,
              files: capture.files,
              patch_excerpt: capture.patch_excerpt,
              session_id: session_id_from(data)
            }

            broadcast_raw(topic, payload)

          {:error, _reason} ->
            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp maybe_broadcast_diff(_, _), do: :ok

  defp worktree_from_artifact(%{worktree_path: path}) when is_binary(path), do: path
  defp worktree_from_artifact(%{"worktree_path" => path}) when is_binary(path), do: path
  defp worktree_from_artifact(_), do: nil

  defp session_id_from(%{work_unit: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id_from(%{work_unit: %{"session_id" => sid}}) when is_binary(sid), do: sid
  defp session_id_from(_), do: nil

  defp broadcast_raw(topic, payload) when is_binary(topic) and is_map(payload) do
    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {topic, payload})
    end
  rescue
    _ -> :ok
  end

  defp notify_owner(%{owner: pid}, status) when is_pid(pid) do
    send(pid, {:work_unit_pipeline, self(), status})
  end

  defp notify_owner(_, _), do: :ok
end
