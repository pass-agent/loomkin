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

  # State: %{sessions: %{session_id => {session, timer_ref}}}

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
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:request_healing, team_id, agent_name, healing_context}, _from, state) do
    session = %Session{
      id: Ecto.UUID.generate(),
      team_id: team_id,
      agent_name: agent_name,
      classification: healing_context[:classification] || healing_context,
      error_context: healing_context,
      status: :diagnosing,
      started_at: DateTime.utc_now(),
      budget_remaining_usd: @default_budget_usd,
      max_iterations: @default_max_iterations,
      attempts: 0,
      max_attempts: @default_max_attempts
    }

    Logger.info(
      "[Kin:healing] session started id=#{session.id} agent=#{agent_name} team=#{team_id} category=#{inspect(session.classification[:category])}"
    )

    timer_ref = Process.send_after(self(), {:healing_timeout, session.id}, @default_timeout_ms)
    state = put_in(state, [:sessions, session.id], {session, timer_ref})

    # Spawn diagnostician — ephemeral agent system (14.4) will handle this.
    # For now, emit a signal so the orchestrator is functional once 14.4 lands.
    spawn_diagnostician(session)

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

        # Spawn fixer with diagnosis context
        spawn_fixer(session)

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

        summary = %{
          description: "Self-healing completed",
          root_cause: get_in(session.diagnosis, [:root_cause]) || "Diagnosed issue",
          fix_description: fix_result[:description] || "Fix applied",
          files_changed: fix_result[:files_changed] || []
        }

        wake_agent(session, summary)
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

          session = %{session | status: :diagnosing}
          state = put_in(state, [:sessions, session_id], {session, timer_ref})

          spawn_diagnostician(session, retry_context: reason)

          {:reply, :ok, state}
        else
          Logger.warning(
            "[Kin:healing] fix failed, escalating id=#{session_id} attempts=#{session.attempts}"
          )

          cancel_timer(timer_ref)

          session = %{session | status: :failed}
          escalate(session, reason)
          wake_with_failure(session, reason)

          state = remove_session(state, session_id)
          {:reply, :ok, state}
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

  # --- Timeout handler ---

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
        cleanup_healing_agents(session)

        state = remove_session(state, session_id)
        {:noreply, state}
    end
  end

  # Ignore stale timer messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
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
    reason_text = if is_binary(reason), do: reason, else: inspect(reason)

    summary = %{
      description: "Self-healing failed",
      root_cause: get_in(session.diagnosis, [:root_cause]) || "Unknown",
      fix_description: "Healing failed: #{reason_text}. Manual intervention may be needed."
    }

    wake_agent(session, summary)
  end

  defp escalate(session, reason) do
    reason_text = if is_binary(reason), do: reason, else: inspect(reason)

    Logger.warning(
      "[Kin:healing] escalating id=#{session.id} agent=#{session.agent_name} reason=#{reason_text}"
    )

    # Publish escalation signal so the team lead and workspace are notified
    try do
      Loomkin.Signals.Agent.Error.new!(%{
        agent_name: to_string(session.agent_name),
        team_id: session.team_id,
        reason: "Healing escalation: #{reason_text}"
      })
      |> Loomkin.Signals.publish()
    rescue
      _ -> :ok
    end
  end

  @ephemeral_agent_module Loomkin.Healing.EphemeralAgent

  defp spawn_diagnostician(session, opts \\ []) do
    Logger.info(
      "[Kin:healing] spawning diagnostician id=#{session.id} retry=#{opts[:retry_context] != nil}"
    )

    # Delegate to EphemeralAgent (14.4) when available.
    # Uses dynamic apply to avoid compile-time warning before 14.4 lands.
    try do
      if Code.ensure_loaded?(@ephemeral_agent_module) do
        apply(@ephemeral_agent_module, :start, [
          [
            role: :diagnostician,
            team_id: session.team_id,
            session_id: session.id,
            classification: session.classification,
            error_context: session.error_context,
            retry_context: opts[:retry_context],
            max_iterations: div(session.max_iterations, 2),
            budget_usd: session.budget_remaining_usd * 0.4
          ]
        ])
      end
    rescue
      e ->
        Logger.warning("[Kin:healing] failed to spawn diagnostician: #{Exception.message(e)}")
    end
  end

  defp spawn_fixer(session) do
    Logger.info("[Kin:healing] spawning fixer id=#{session.id}")

    try do
      if Code.ensure_loaded?(@ephemeral_agent_module) do
        apply(@ephemeral_agent_module, :start, [
          [
            role: :fixer,
            team_id: session.team_id,
            session_id: session.id,
            diagnosis: session.diagnosis,
            classification: session.classification,
            max_iterations: div(session.max_iterations, 2),
            budget_usd: session.budget_remaining_usd * 0.6
          ]
        ])
      end
    rescue
      e ->
        Logger.warning("[Kin:healing] failed to spawn fixer: #{Exception.message(e)}")
    end
  end

  defp cleanup_healing_agents(session) do
    for agent_id <- [session.diagnostician_id, session.fixer_id],
        agent_id != nil do
      try do
        Manager.dissolve_team(agent_id)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
