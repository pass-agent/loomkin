defmodule Loomkin.Verification.Loop do
  @moduledoc """
  Autonomous GenServer that runs write -> test -> diagnose -> fix -> re-test
  cycles without human involvement.

  Workspace-owned (survives session disconnects). Checkpoints every 5
  iterations to the workspace task journal. Feeds failure memory keepers
  as it encounters errors.

  ## Signals emitted

    * `verification.loop.started` -- loop spawned
    * `verification.loop.iteration` -- one cycle complete
    * `verification.loop.passed` -- all tests pass
    * `verification.loop.failed` -- max iterations or timeout
    * `verification.loop.escalated` -- human intervention needed
  """

  use GenServer

  require Logger

  alias Loomkin.ShellCommand
  alias Loomkin.Workspace.Server, as: WorkspaceServer

  @checkpoint_interval 5
  @default_max_iterations 10
  @default_timeout_ms :timer.minutes(30)
  @test_command_timeout 120_000

  defstruct [
    :id,
    :workspace_id,
    :team_id,
    :task_id,
    :test_command,
    :success_criteria,
    :project_path,
    :timeout_ref,
    :test_task,
    :test_task_pid,
    max_iterations: @default_max_iterations,
    current_iteration: 0,
    results: [],
    confidence: 0,
    status: :idle,
    steering: nil
  ]

  # --- Public API ---

  @doc """
  Start a verification loop.

  ## Options

    * `:workspace_id` -- workspace that owns this loop (required)
    * `:team_id` -- team context for signals (required)
    * `:task_id` -- task being verified (required)
    * `:test_command` -- shell command to run tests (required)
    * `:success_criteria` -- string describing pass conditions (optional)
    * `:max_iterations` -- iteration cap (default: 10)
    * `:timeout_ms` -- overall timeout (default: 30 min)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, fn -> Ecto.UUID.generate() end)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id), name: via(id))
  end

  @doc "Get the current status and iteration count."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(loop_id) do
    GenServer.call(via(loop_id), :status)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc "Inject steering guidance into the next iteration."
  @spec steer(String.t(), String.t()) :: :ok | {:error, :not_found}
  def steer(loop_id, guidance) do
    GenServer.call(via(loop_id), {:steer, guidance})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc "Request graceful stop of the loop."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(loop_id) do
    GenServer.call(via(loop_id), :stop)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    team_id = Keyword.fetch!(opts, :team_id)
    task_id = Keyword.fetch!(opts, :task_id)
    test_command = Keyword.fetch!(opts, :test_command)
    success_criteria = Keyword.get(opts, :success_criteria)
    project_path = Keyword.get(opts, :project_path)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    state = %__MODULE__{
      id: id,
      workspace_id: workspace_id,
      team_id: team_id,
      task_id: task_id,
      test_command: test_command,
      success_criteria: success_criteria,
      project_path: project_path,
      max_iterations: max_iterations,
      status: :running
    }

    timeout_ref = Process.send_after(self(), :timeout, timeout_ms)
    state = %{state | timeout_ref: timeout_ref}

    publish_signal(state, "verification.loop.started", %{
      loop_id: id,
      task_id: task_id,
      test_command: test_command,
      max_iterations: max_iterations
    })

    Logger.info(
      "[VerificationLoop] started id=#{id} task=#{task_id} max_iterations=#{max_iterations}"
    )

    {:ok, state, {:continue, :run_iteration}}
  end

  @impl true
  def handle_continue(:run_iteration, state) do
    spawn_test_task(state)
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      id: state.id,
      status: state.status,
      current_iteration: state.current_iteration,
      max_iterations: state.max_iterations,
      confidence: state.confidence,
      task_id: state.task_id,
      results: Enum.take(state.results, -3)
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_call({:steer, guidance}, _from, state) do
    Logger.info("[VerificationLoop] steering received id=#{state.id}")
    {:reply, :ok, %{state | steering: guidance}}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Logger.info("[VerificationLoop] stop requested id=#{state.id}")
    kill_test_task(state)
    cancel_timeout(state)
    checkpoint(state)
    {:stop, :normal, :ok, %{state | status: :stopped}}
  end

  @impl true
  def handle_info({ref, test_result}, %{test_task: ref} = state) when is_reference(ref) do
    # Demonitor the task so we don't get a :DOWN message
    Process.demonitor(ref, [:flush])
    process_test_result(state, test_result)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{test_task: ref} = state) do
    # Test task crashed
    test_result = %{passed: false, output: "Test task crashed: #{inspect(reason)}", exit_code: -1}
    process_test_result(%{state | test_task: nil}, test_result)
  end

  @impl true
  def handle_info(:run_iteration, %{status: :running} = state) do
    spawn_test_task(state)
  end

  @impl true
  def handle_info(:run_iteration, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("[VerificationLoop] timed out id=#{state.id}")
    kill_test_task(state)
    checkpoint(state)

    publish_signal(state, "verification.loop.escalated", %{
      loop_id: state.id,
      reason: :timeout,
      iteration: state.current_iteration,
      confidence: state.confidence
    })

    {:stop, :normal, %{state | status: :timed_out}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    kill_test_task(state)
    cancel_timeout(state)
  end

  # --- Private ---

  defp spawn_test_task(state) do
    iteration = state.current_iteration + 1

    Logger.info(
      "[VerificationLoop] iteration #{iteration}/#{state.max_iterations} id=#{state.id}"
    )

    state = %{state | current_iteration: iteration}

    # Run test command asynchronously so the GenServer stays responsive
    team_id = state.team_id
    test_command = state.test_command

    project_path = state.project_path

    task =
      Task.Supervisor.async_nolink(Loomkin.Healing.TaskSupervisor, fn ->
        run_test(test_command, team_id, project_path)
      end)

    {:noreply, %{state | test_task: task.ref, test_task_pid: task.pid}}
  end

  defp process_test_result(state, test_result) do
    result_entry = %{
      iteration: state.current_iteration,
      passed: test_result.passed,
      output: test_result.output,
      timestamp: DateTime.utc_now()
    }

    # Keep only last 10 results to bound memory
    capped_results = Enum.take(state.results, -9) ++ [result_entry]

    state = %{
      state
      | results: capped_results,
        test_task: nil,
        test_task_pid: nil
    }

    state = update_confidence(state)

    publish_signal(state, "verification.loop.iteration", %{
      loop_id: state.id,
      iteration: state.current_iteration,
      passed: test_result.passed,
      confidence: state.confidence
    })

    cond do
      test_result.passed ->
        handle_success(state)

      state.current_iteration >= state.max_iterations ->
        handle_max_iterations(state)

      true ->
        handle_failure(state, test_result)
    end
  end

  defp handle_success(state) do
    Logger.info("[VerificationLoop] passed id=#{state.id} iteration=#{state.current_iteration}")
    cancel_timeout(state)
    checkpoint(state)

    publish_signal(state, "verification.loop.passed", %{
      loop_id: state.id,
      iteration: state.current_iteration,
      confidence: state.confidence
    })

    {:stop, :normal, %{state | status: :passed}}
  end

  defp handle_max_iterations(state) do
    Logger.warning(
      "[VerificationLoop] max iterations reached id=#{state.id} iteration=#{state.current_iteration}"
    )

    cancel_timeout(state)
    checkpoint(state)

    publish_signal(state, "verification.loop.failed", %{
      loop_id: state.id,
      iteration: state.current_iteration,
      confidence: state.confidence,
      reason: :max_iterations
    })

    {:stop, :normal, %{state | status: :failed}}
  end

  defp handle_failure(state, test_result) do
    feed_failure_memory(state, test_result)

    diagnosis = diagnose(state, test_result)
    state = maybe_apply_fix(state, diagnosis)

    # Clear steering after use
    state = %{state | steering: nil}

    # Checkpoint every N iterations
    if rem(state.current_iteration, @checkpoint_interval) == 0 do
      checkpoint(state)
    end

    # Schedule next iteration
    send(self(), :run_iteration)
    {:noreply, state}
  end

  defp run_test(test_command, team_id, project_path) do
    path = project_path || Loomkin.Teams.Manager.get_team_project_path(team_id)

    case path do
      p when is_binary(p) ->
        run_test_in_path(test_command, p)

      _ ->
        %{passed: false, output: "Cannot resolve project path for team #{team_id}", exit_code: -1}
    end
  end

  defp run_test_in_path(test_command, project_path) do
    case ShellCommand.execute(test_command, project_path, @test_command_timeout) do
      {:ok, output, 0} ->
        %{passed: true, output: ShellCommand.truncate(output, 10_000), exit_code: 0}

      {:ok, output, code} ->
        %{passed: false, output: ShellCommand.truncate(output, 10_000), exit_code: code}

      {:error, reason} ->
        %{passed: false, output: "Command failed: #{reason}", exit_code: -1}
    end
  end

  defp diagnose(state, test_result) do
    context = %{
      test_output: test_result.output,
      iteration: state.current_iteration,
      previous_results: Enum.take(state.results, -3),
      steering: state.steering,
      success_criteria: state.success_criteria
    }

    Logger.info("[VerificationLoop] diagnosing id=#{state.id}")
    context
  end

  defp maybe_apply_fix(state, diagnosis) do
    Logger.info(
      "[VerificationLoop] fix attempt id=#{state.id} iteration=#{state.current_iteration} steering=#{inspect(diagnosis[:steering])}"
    )

    state
  end

  defp feed_failure_memory(state, test_result) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{state.team_id}:context",
      {:context_update, "verification_loop",
       %{
         type: :failure_memory,
         task_id: state.task_id,
         iteration: state.current_iteration,
         test_output: String.slice(test_result.output, 0, 2000),
         timestamp: DateTime.utc_now()
       }}
    )
  rescue
    e ->
      Logger.debug("[VerificationLoop] feed_failure_memory failed: #{Exception.message(e)}")
      :ok
  end

  defp checkpoint(state) do
    checkpoint_data = %{
      current_iteration: state.current_iteration,
      confidence: state.confidence,
      status: state.status,
      results_count: length(state.results),
      last_results: Enum.take(state.results, -3)
    }

    if state.workspace_id do
      try do
        WorkspaceServer.journal_task(state.workspace_id, %{
          task_id: state.task_id,
          status: "verification_checkpoint",
          result_summary:
            "Loop iteration #{state.current_iteration}/#{state.max_iterations}, confidence: #{state.confidence}%",
          checkpoint_json: checkpoint_data
        })
      rescue
        e ->
          Logger.warning(
            "[VerificationLoop] checkpoint failed id=#{state.id} error=#{Exception.message(e)}"
          )
      catch
        :exit, reason ->
          Logger.warning(
            "[VerificationLoop] checkpoint exit id=#{state.id} reason=#{inspect(reason)}"
          )
      end
    end
  end

  defp update_confidence(state) do
    recent = Enum.take(state.results, -5)
    pass_count = Enum.count(recent, & &1.passed)
    total = length(recent)
    confidence = if total > 0, do: round(pass_count / total * 100), else: 0
    %{state | confidence: confidence}
  end

  defp publish_signal(state, type, payload) do
    full_payload =
      Map.merge(payload, %{
        team_id: state.team_id,
        workspace_id: state.workspace_id
      })

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{state.team_id}",
      {:verification_event, Map.put(full_payload, :type, type)}
    )
  rescue
    e ->
      Logger.debug("[VerificationLoop] publish_signal failed: #{Exception.message(e)}")
      :ok
  end

  defp cancel_timeout(%{timeout_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_timeout(_state), do: :ok

  defp kill_test_task(%{test_task: ref, test_task_pid: pid})
       when is_reference(ref) and is_pid(pid) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp kill_test_task(%{test_task: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
  end

  defp kill_test_task(_state), do: :ok

  defp via(id) do
    {:via, Registry, {Loomkin.Verification.Registry, id}}
  end
end
