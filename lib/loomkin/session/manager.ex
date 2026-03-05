defmodule Loomkin.Session.Manager do
  @moduledoc """
  Manages session lifecycle: start, stop, list, and find sessions.

  Every session is backed by a team of one (lead agent) that can spawn helpers.
  The Session GenServer handles persistence and PubSub, while delegating the
  agent loop to Teams.Agent when a team is active.
  """

  alias Loomkin.Session

  require Logger

  @doc """
  Start a new session under the DynamicSupervisor.

  Also creates a backing team with a lead agent so team tools are available
  from the start. The session remains the primary interface — the team
  is an implementation detail that activates when the lead spawns helpers.
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    session_id = opts[:session_id] || Ecto.UUID.generate()
    opts = Keyword.put(opts, :session_id, session_id)

    # Ensure tools include team/lead tools so the architect can spawn teams
    tools = Keyword.get(opts, :tools, Loomkin.Tools.Registry.all())
    opts = Keyword.put(opts, :tools, ensure_lead_tools(tools))

    child_spec = {Session, opts}

    case DynamicSupervisor.start_child(Loomkin.SessionSupervisor, child_spec) do
      {:ok, pid} ->
        maybe_create_backing_team(session_id, opts)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Ensure secondary callers also get team wiring by re-broadcasting
        # the team_id if the session already has one.
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          try do
            case Session.get_team_id(pid) do
              nil -> :ok
              team_id -> broadcast(session_id, {:team_available, session_id, team_id})
            end
          catch
            _, _ -> :ok
          end
        end)

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ensure lead tools are present in the tool list
  defp ensure_lead_tools(tools) do
    lead_tools = Loomkin.Tools.Registry.lead_tools()
    existing_names = MapSet.new(tools)

    missing = Enum.reject(lead_tools, &(&1 in existing_names))
    tools ++ missing
  end

  @doc "Find an agent by name within a team."
  @spec find_agent(String.t(), String.t()) :: {:ok, pid()} | :error
  def find_agent(team_id, agent_name) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, agent_name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # Create a backing team (without agents) for this session.
  # Bootstrap agents (Concierge + Orienter) are spawned lazily on first user message
  # so the user has time to select the correct project path first.
  # This is best-effort — if it fails, the session still works without teams.
  defp maybe_create_backing_team(session_id, opts) do
    project_path = Keyword.get(opts, :project_path)

    Logger.debug(
      "[Session.Manager] maybe_create_backing_team session=#{session_id}"
    )

    try do
      {:ok, team_id} =
        Loomkin.Teams.Manager.create_team(
          name: "session-#{String.slice(session_id, 0, 8)}",
          project_path: project_path
        )

      Logger.info("[Session.Manager] Team created team_id=#{team_id} for session=#{session_id}")

      # Persist team_id to the session DB record
      persist_team_id(session_id, team_id)

      # Notify the session process about its team
      case Registry.lookup(Loomkin.SessionRegistry, session_id) do
        [{pid, _}] ->
          Logger.info("[Session.Manager] Sending :team_created to session pid=#{inspect(pid)}")
          send(pid, {:team_created, team_id})

        [] ->
          Logger.error("[Session.Manager] Session NOT FOUND in registry! session=#{session_id}")
      end
    rescue
      e ->
        Logger.error(
          "[Session.Manager] Error creating backing team: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )
    end
  end

  defp persist_team_id(session_id, team_id) do
    case Loomkin.Session.Persistence.get_session(session_id) do
      nil ->
        Logger.warning(
          "[Session.Manager] Cannot persist team_id — session #{session_id} not found"
        )

      db_session ->
        case Loomkin.Session.Persistence.update_session(db_session, %{team_id: team_id}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Session.Manager] Failed to persist team_id: #{inspect(reason)}")
        end
    end
  end

  @doc "Stop a session gracefully, dissolving its backing team."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case find_session(session_id) do
      {:ok, pid} ->
        # Retrieve team_id before stopping the session process
        team_id =
          try do
            Session.get_team_id(pid)
          catch
            _, _ -> nil
          end

        GenServer.stop(pid, :normal)

        # Dissolve the backing team to clean up ETS tables and agent processes
        if team_id do
          Loomkin.Teams.Manager.dissolve_team(team_id)

          Logger.debug(
            "[Session.Manager] Dissolved backing team #{team_id} for session #{session_id}"
          )
        end

        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc "List active session PIDs with metadata."
  @spec list_active() :: [%{id: String.t(), pid: pid(), status: atom()}]
  def list_active do
    Registry.select(Loomkin.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [%{id: :"$1", pid: :"$2", status: :"$3"}]}
    ])
  end

  @doc "Find a session process by ID."
  @spec find_session(String.t()) :: {:ok, pid()} | :error
  def find_session(session_id) do
    case Registry.lookup(Loomkin.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(Loomkin.PubSub, "session:#{session_id}", message)
  end
end
