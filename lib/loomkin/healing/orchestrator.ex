defmodule Loomkin.Healing.Orchestrator do
  @moduledoc """
  Central coordinator for the self-healing lifecycle.

  Manages active healing sessions: receives healing requests from suspended
  agents, spawns ephemeral diagnostician/fixer agents, tracks progress,
  enforces budgets and timeouts, and triggers agent wake on completion.
  """

  use GenServer

  require Logger

  alias Loomkin.Healing.Session
  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Manager

  @default_budget_usd 0.50
  @default_max_iterations 15
  @default_max_attempts 2
  @default_timeout_ms :timer.minutes(5)

  # State: %{sessions: %{session_id => {session, timer_ref}}, monitors: %{monitor_ref => session_id}}

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Request healing for a suspended agent."
  @spec request_healing(String.t(), atom() | String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def request_healing(team_id, agent_name, healing_context) do
    GenServer.call(__MODULE__, {:request_healing, team_id, agent_name, healing_context})
  end

  @doc "Receive diagnosis report from diagnostician agent."
  @spec report_diagnosis(String.t(), map()) :: :ok | {:error, term()}
  def report_diagnosis(session_id, diagnosis) do
    GenServer.call(__MODULE__, {:report_diagnosis, session_id, diagnosis})
  end

  @doc "Receive fix confirmation from fixer agent."
  @spec confirm_fix(String.t(), map()) :: :ok | {:error, term()}
  def confirm_fix(session_id, fix_result) do
    GenServer.call(__MODULE__, {:confirm_fix, session_id, fix_result})
  end

  @doc "Report a failed fix attempt — retries or escalates."
  @spec fix_failed(String.t(), String.t()) :: :ok | {:error, term()}
  def fix_failed(session_id, description) do
    GenServer.call(__MODULE__, {:fix_failed, session_id, description})
  end

  @doc "Report a failed diagnosis attempt — retries or escalates."
  @spec diagnose_failed(String.t(), String.t()) :: :ok | {:error, term()}
  def diagnose_failed(session_id, description) do
    GenServer.call(__MODULE__, {:diagnose_failed, session_id, description})
  end

  @doc "Cancel an active healing session and wake the agent."
  @spec cancel_healing(String.t()) :: :ok | {:error, :not_found}
  def cancel_healing(session_id) do
    GenServer.call(__MODULE__, {:cancel_healing, session_id})
  end

  @doc "Get all active healing sessions for a team."
  @spec active_sessions(String.t()) :: [Session.t()]
  def active_sessions(team_id) do
    GenServer.call(__MODULE__, {:active_sessions, team_id})
  end

  @doc "Get a specific healing session by ID."
  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:request_healing, team_id, agent_name, healing_context}, _from, state) do
    budget = healing_context[:budget_usd] || @default_budget_usd
    timeout = healing_context[:timeout_ms] || @default_timeout_ms
    max_attempts = healing_context[:max_attempts] || @default_max_attempts

    session = %Session{
      id: Ecto.UUID.generate(),
      team_id: team_id,
      agent_name: agent_name,
      classification: healing_context[:classification] || healing_context,
      error_context: healing_context,
      status: :diagnosing,
      started_at: DateTime.utc_now(),
      budget_remaining_usd: budget,
      max_iterations: @default_max_iterations,
      attempts: 0,
      max_attempts: max_attempts
    }

    Logger.info(
      "[Kin:healing] session started id=#{session.id} agent=#{agent_name} team=#{team_id} category=#{inspect(session.classification[:category])}"
    )

    timer_ref = Process.send_after(self(), {:healing_timeout, session.id}, timeout)
    state = put_in(state, [:sessions, session.id], {session, timer_ref})

    publish_session_started(session)

    state = spawn_and_track_diagnostician(state, session)

    {:reply, {:ok, session.id}, state}
  end

  @impl true
  def handle_call({:report_diagnosis, session_id, diagnosis}, _from, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {session, timer_ref} ->
        session = %{
          session
          | diagnosis: diagnosis,
            status: :fixing,
            attempts: session.attempts + 1
        }

        Logger.info(
          "[Kin:healing] diagnosis received id=#{session_id} root_cause=#{inspect(diagnosis[:root_cause])}"
        )

        state = put_in(state, [:sessions, session_id], {session, timer_ref})

        publish_diagnosis_complete(session, diagnosis)

        state = spawn_and_track_fixer(state, session)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:confirm_fix, session_id, fix_result}, _from, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {session, timer_ref} ->
        session = %{session | fix_result: fix_result, status: :complete}

        Logger.info("[Kin:healing] fix confirmed id=#{session_id} agent=#{session.agent_name}")

        cancel_timer(timer_ref)

        root_cause =
          case session.diagnosis do
            %{root_cause: rc} when is_binary(rc) -> rc
            _ -> "Diagnosed issue"
          end

        summary = %{
          description: "Self-healing completed",
          root_cause: root_cause,
          fix_description: fix_result[:description] || "Fix applied",
          files_changed: fix_result[:files_changed] || []
        }

        wake_agent(session, summary)
        publish_fix_applied(session, fix_result)
        publish_session_complete(session, :healed)
        cleanup_healing_agents(session)

        state = remove_session(state, session_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:fix_failed, session_id, reason}, _from, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {session, timer_ref} ->
        if session.attempts < session.max_attempts do
          Logger.info(
            "[Kin:healing] fix failed, retrying id=#{session_id} attempt=#{session.attempts}/#{session.max_attempts}"
          )

          session = %{session | status: :diagnosing, fixer_pid: nil}
          state = put_in(state, [:sessions, session_id], {session, timer_ref})

          state = spawn_and_track_diagnostician(state, session, retry_context: reason)

          {:reply, :ok, state}
        else
          complete_with_failure(state, session, timer_ref, reason, :escalated)
        end
    end
  end

  @impl true
  def handle_call({:diagnose_failed, session_id, reason}, _from, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {session, timer_ref} ->
        # Increment attempts on diagnosis failure to prevent infinite loops
        session = %{session | attempts: session.attempts + 1, diagnostician_pid: nil}

        if session.attempts < session.max_attempts do
          Logger.info(
            "[Kin:healing] diagnosis failed, retrying id=#{session_id} attempt=#{session.attempts}/#{session.max_attempts}"
          )

          state = put_in(state, [:sessions, session_id], {session, timer_ref})

          state = spawn_and_track_diagnostician(state, session, retry_context: reason)

          {:reply, :ok, state}
        else
          complete_with_failure(state, session, timer_ref, reason, :escalated)
        end
    end
  end

  @impl true
  def handle_call({:cancel_healing, session_id}, _from, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {session, timer_ref} ->
        Logger.info("[Kin:healing] session cancelled id=#{session_id}")

        cancel_timer(timer_ref)

        session = %{session | status: :cancelled}
        cleanup_healing_agents(session)

        wake_with_failure(session, "Healing cancelled by user or system")

        state = remove_session(state, session_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:active_sessions, team_id}, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.map(fn {session, _timer} -> session end)
      |> Enum.filter(fn session -> session.team_id == team_id end)

    {:reply, sessions, state}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case get_session_entry(state, session_id) do
      nil -> {:reply, nil, state}
      {session, _timer} -> {:reply, session, state}
    end
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:healing_timeout, session_id}, state) do
    case get_session_entry(state, session_id) do
      nil ->
        {:noreply, state}

      {session, _timer_ref} ->
        Logger.warning(
          "[Kin:healing] session timed out id=#{session_id} agent=#{session.agent_name}"
        )

        session = %{session | status: :timed_out}
        escalate(session, :timeout)
        wake_with_failure(session, "Healing timed out after #{@default_timeout_ms}ms")
        publish_session_complete(session, :timed_out)
        cleanup_healing_agents(session)

        state = remove_session(state, session_id)
        {:noreply, state}
    end
  end

  # Handle ephemeral agent process crashes (S4 fix)
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {session_id, monitors} ->
        state = %{state | monitors: monitors}

        case get_session_entry(state, session_id) do
          nil ->
            {:noreply, state}

          {session, timer_ref} ->
            # Only handle abnormal exits — normal exits mean the agent completed
            # and should have already reported via tool call
            if reason != :normal do
              Logger.warning(
                "[Kin:healing] ephemeral agent crashed id=#{session_id} reason=#{inspect(reason)}"
              )

              # Increment attempts and decide whether to retry or escalate
              session = %{
                session
                | attempts: session.attempts + 1,
                  diagnostician_pid: nil,
                  fixer_pid: nil
              }

              if session.attempts < session.max_attempts do
                state = put_in(state, [:sessions, session_id], {session, timer_ref})

                state =
                  spawn_and_track_diagnostician(state, session,
                    retry_context: "Agent crashed: #{inspect(reason)}"
                  )

                {:noreply, state}
              else
                {_reply, :ok, state} =
                  complete_with_failure(
                    state,
                    session,
                    timer_ref,
                    "Agent crashed: #{inspect(reason)}",
                    :escalated
                  )

                {:noreply, state}
              end
            else
              {:noreply, state}
            end
        end
    end
  end

  # Ignore stale timer messages and other unexpected messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Wake all suspended agents on orchestrator shutdown (I1 fix)
  @impl true
  def terminate(reason, state) do
    if map_size(state.sessions) > 0 do
      Logger.warning(
        "[Kin:healing] orchestrator terminating with #{map_size(state.sessions)} active sessions reason=#{inspect(reason)}"
      )

      for {_id, {session, timer_ref}} <- state.sessions do
        cancel_timer(timer_ref)
        wake_with_failure(session, "Healing orchestrator restarted")
      end
    end

    :ok
  end

  # --- Helpers ---

  defp get_session_entry(state, session_id) do
    Map.get(state.sessions, session_id)
  end

  defp remove_session(state, session_id) do
    %{state | sessions: Map.delete(state.sessions, session_id)}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp complete_with_failure(state, session, timer_ref, reason, outcome) do
    Logger.warning(
      "[Kin:healing] healing #{outcome} id=#{session.id} agent=#{session.agent_name} attempts=#{session.attempts}"
    )

    cancel_timer(timer_ref)

    session = %{session | status: :failed}
    escalate(session, reason)
    wake_with_failure(session, reason)
    publish_session_complete(session, outcome)
    cleanup_healing_agents(session)

    state = remove_session(state, session.id)
    {:reply, :ok, state}
  end

  defp wake_agent(session, summary) do
    case Manager.find_agent(session.team_id, session.agent_name) do
      {:ok, pid} ->
        Agent.wake_from_healing(pid, summary)

      :error ->
        Logger.warning(
          "[Kin:healing] agent not found for wake agent=#{session.agent_name} team=#{session.team_id}"
        )
    end
  end

  defp wake_with_failure(session, reason) do
    reason_text = format_reason(reason)

    root_cause =
      case session.diagnosis do
        %{root_cause: rc} when is_binary(rc) -> rc
        _ -> "Unknown"
      end

    summary = %{
      description: "Self-healing failed",
      root_cause: root_cause,
      fix_description: "Healing failed: #{reason_text}. Manual intervention may be needed."
    }

    wake_agent(session, summary)
  end

  defp escalate(session, reason) do
    reason_text = format_reason(reason)

    Logger.warning(
      "[Kin:healing] escalating id=#{session.id} agent=#{session.agent_name} reason=#{reason_text}"
    )

    try do
      Loomkin.Signals.Agent.Error.new!(%{
        agent_name: to_string(session.agent_name),
        team_id: session.team_id,
        reason: "Healing escalation: #{reason_text}"
      })
      |> Loomkin.Signals.publish()
    rescue
      e ->
        Logger.warning(
          "[Kin:healing] failed to publish escalation signal: #{Exception.message(e)}"
        )
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # --- Ephemeral agent spawning with monitoring ---

  defp ephemeral_agent_module do
    Application.get_env(:loomkin, :healing_ephemeral_agent, Loomkin.Healing.EphemeralAgent)
  end

  defp spawn_and_track_diagnostician(state, session, opts \\ []) do
    Logger.info(
      "[Kin:healing] spawning diagnostician id=#{session.id} retry=#{opts[:retry_context] != nil}"
    )

    budget_slice = session.budget_remaining_usd * 0.4

    {:ok, pid} =
      ephemeral_agent_module().start(
        role: :diagnostician,
        team_id: session.team_id,
        session_id: session.id,
        classification: session.classification,
        error_context: session.error_context,
        retry_context: opts[:retry_context],
        max_iterations: div(session.max_iterations, 2),
        budget_usd: budget_slice
      )

    ref = Process.monitor(pid)

    session = %{
      session
      | diagnostician_pid: pid,
        budget_remaining_usd: session.budget_remaining_usd - budget_slice
    }

    {_old_session, timer_ref} = Map.get(state.sessions, session.id, {nil, nil})
    state = put_in(state, [:sessions, session.id], {session, timer_ref})
    %{state | monitors: Map.put(state.monitors, ref, session.id)}
  rescue
    e ->
      Logger.warning("[Kin:healing] failed to spawn diagnostician: #{Exception.message(e)}")
      state
  end

  defp spawn_and_track_fixer(state, session) do
    Logger.info("[Kin:healing] spawning fixer id=#{session.id}")

    budget_slice = session.budget_remaining_usd * 0.6

    {:ok, pid} =
      ephemeral_agent_module().start(
        role: :fixer,
        team_id: session.team_id,
        session_id: session.id,
        diagnosis: session.diagnosis,
        classification: session.classification,
        max_iterations: div(session.max_iterations, 2),
        budget_usd: budget_slice
      )

    ref = Process.monitor(pid)

    session = %{
      session
      | fixer_pid: pid,
        budget_remaining_usd: session.budget_remaining_usd - budget_slice
    }

    {_old_session, timer_ref} = Map.get(state.sessions, session.id, {nil, nil})
    state = put_in(state, [:sessions, session.id], {session, timer_ref})
    %{state | monitors: Map.put(state.monitors, ref, session.id)}
  rescue
    e ->
      Logger.warning("[Kin:healing] failed to spawn fixer: #{Exception.message(e)}")
      state
  end

  defp cleanup_healing_agents(session) do
    for pid <- [session.diagnostician_pid, session.fixer_pid],
        is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end
  end

  # --- Signal publishing (S3 fix) ---

  defp publish_session_started(session) do
    Loomkin.Signals.Healing.SessionStarted.new!(%{
      session_id: session.id,
      team_id: session.team_id,
      agent_name: to_string(session.agent_name),
      classification: session.classification
    })
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning(
        "[Kin:healing] failed to publish session started signal: #{Exception.message(e)}"
      )
  end

  defp publish_diagnosis_complete(session, diagnosis) do
    Loomkin.Signals.Healing.DiagnosisComplete.new!(%{
      session_id: session.id,
      team_id: session.team_id,
      agent_name: to_string(session.agent_name),
      root_cause: diagnosis[:root_cause] || "Unknown",
      confidence: diagnosis[:confidence] || 0.0
    })
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning(
        "[Kin:healing] failed to publish diagnosis complete signal: #{Exception.message(e)}"
      )
  end

  defp publish_fix_applied(session, fix_result) do
    Loomkin.Signals.Healing.FixApplied.new!(%{
      session_id: session.id,
      team_id: session.team_id,
      agent_name: to_string(session.agent_name),
      files_changed: fix_result[:files_changed] || []
    })
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning(
        "[Kin:healing] failed to publish fix applied signal: #{Exception.message(e)}"
      )
  end

  defp publish_session_complete(session, outcome) do
    duration_ms = DateTime.diff(DateTime.utc_now(), session.started_at, :millisecond)

    Loomkin.Signals.Healing.SessionComplete.new!(%{
      session_id: session.id,
      team_id: session.team_id,
      agent_name: to_string(session.agent_name),
      outcome: outcome,
      duration_ms: duration_ms
    })
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning(
        "[Kin:healing] failed to publish session complete signal: #{Exception.message(e)}"
      )
  end
end
