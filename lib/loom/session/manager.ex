defmodule Loom.Session.Manager do
  @moduledoc """
  Manages session lifecycle: start, stop, list, and find sessions.

  Every session is backed by a team of one (lead agent) that can spawn helpers.
  The Session GenServer handles persistence and PubSub, while delegating the
  agent loop to Teams.Agent when a team is active.
  """

  alias Loom.Session

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
    tools = Keyword.get(opts, :tools, Loom.Tools.Registry.all())
    opts = Keyword.put(opts, :tools, ensure_lead_tools(tools))

    child_spec = {Session, opts}

    case DynamicSupervisor.start_child(Loom.SessionSupervisor, child_spec) do
      {:ok, pid} ->
        maybe_create_backing_team(session_id, opts)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Ensure secondary callers also get team wiring by re-broadcasting
        # the team_id if the session already has one.
        spawn(fn ->
          try do
            case GenServer.call(pid, :get_team_id, 5_000) do
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
    lead_tools = Loom.Tools.Registry.lead_tools()
    existing_names = MapSet.new(tools)

    missing = Enum.reject(lead_tools, &(&1 in existing_names))
    tools ++ missing
  end

  # Create a backing team with a lead agent for this session.
  # This is best-effort — if it fails, the session still works without teams.
  defp maybe_create_backing_team(session_id, opts) do
    project_path = Keyword.get(opts, :project_path)
    model = Keyword.get(opts, :model)

    Task.start(fn ->
      try do
        {:ok, team_id} = Loom.Teams.Manager.create_team(name: "session-#{String.slice(session_id, 0, 8)}", project_path: project_path)

        # Spawn the lead agent so the team actually has a member
        case Loom.Teams.Manager.spawn_agent(team_id, "lead", :lead, model: model, project_path: project_path) do
          {:ok, _pid} ->
            Logger.debug("[Session.Manager] Created backing team #{team_id} with lead agent for session #{session_id}")

          {:error, reason} ->
            Logger.warning("[Session.Manager] Backing team #{team_id} created but lead agent failed: #{inspect(reason)}")
        end

        # Notify the session process about its team
        case Registry.lookup(Loom.SessionRegistry, session_id) do
          [{pid, _}] -> send(pid, {:team_created, team_id})
          _ -> :ok
        end
      rescue
        e ->
          Logger.warning("[Session.Manager] Error creating backing team: #{Exception.message(e)}")
      end
    end)
  end

  @doc "Stop a session gracefully, dissolving its backing team."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case find_session(session_id) do
      {:ok, pid} ->
        # Retrieve team_id before stopping the session process
        team_id =
          try do
            GenServer.call(pid, :get_team_id, 5_000)
          catch
            _, _ -> nil
          end

        GenServer.stop(pid, :normal)

        # Dissolve the backing team to clean up ETS tables and agent processes
        if team_id do
          Loom.Teams.Manager.dissolve_team(team_id)
          Logger.debug("[Session.Manager] Dissolved backing team #{team_id} for session #{session_id}")
        end

        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc "List active session PIDs with metadata."
  @spec list_active() :: [%{id: String.t(), pid: pid(), status: atom()}]
  def list_active do
    Registry.select(Loom.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [%{id: :"$1", pid: :"$2", status: :"$3"}]}
    ])
  end

  @doc "Find a session process by ID."
  @spec find_session(String.t()) :: {:ok, pid()} | :error
  def find_session(session_id) do
    case Registry.lookup(Loom.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(Loom.PubSub, "session:#{session_id}", message)
  end
end
