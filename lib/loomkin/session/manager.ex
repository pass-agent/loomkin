defmodule Loomkin.Session.Manager do
  @moduledoc """
  Manages session lifecycle: start, stop, list, and find sessions.

  Sessions attach to workspaces which own team lifetime. When a session starts,
  it finds or creates a workspace for the project. The workspace owns the team,
  so agents persist across session disconnects.
  """

  require Logger

  alias Loomkin.Session
  alias Loomkin.Workspace.Server, as: WorkspaceServer

  @doc """
  Start a new session under the DynamicSupervisor.

  Finds or creates a workspace for the project path, then creates a backing
  team under the workspace. The workspace owns team lifetime — sessions
  connect and disconnect freely.
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
        maybe_attach_to_workspace(session_id, opts)
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

  # Find or create a workspace for this session's project, then create a
  # backing team under the workspace. The workspace owns team lifetime —
  # agents persist across session disconnects.
  #
  # Bootstrap agents (Concierge + Weaver) are spawned lazily on first user message
  # so the user has time to select the correct project path first.
  # This is best-effort — if it fails, the session still works without teams.
  defp maybe_attach_to_workspace(session_id, opts) do
    project_path = Keyword.get(opts, :project_path)

    try do
      # Find or create workspace for this project
      workspace_result =
        WorkspaceServer.find_or_start(%{
          project_path: project_path,
          name: Path.basename(project_path || "untitled")
        })

      case workspace_result do
        {:ok, _ws_pid, workspace_id} ->
          # Attach session to workspace
          WorkspaceServer.attach_session(workspace_id, session_id)

          # Persist workspace_id to the session DB record
          persist_workspace_id(session_id, workspace_id)

          # Check if workspace already has a running team
          case WorkspaceServer.get_team_id(workspace_id) do
            team_id when is_binary(team_id) ->
              # Workspace already has a team — reuse it
              Logger.info(
                "[Kin:session] reusing workspace team workspace=#{workspace_id} team=#{team_id} session=#{session_id}"
              )

              persist_team_id(session_id, team_id)
              notify_session(session_id, {:team_created, team_id})

            nil ->
              # No team yet — create one under the workspace
              {:ok, team_id} =
                Loomkin.Teams.Manager.create_team(
                  name: "ws-#{String.slice(workspace_id, 0, 8)}",
                  project_path: project_path
                )

              Logger.info(
                "[Kin:session] backing team created workspace=#{workspace_id} team=#{team_id} session=#{session_id}"
              )

              WorkspaceServer.set_team_id(workspace_id, team_id)
              persist_team_id(session_id, team_id)
              notify_session(session_id, {:team_created, team_id})
          end

        {:error, reason} ->
          Logger.warning(
            "[Kin:session] workspace attach failed session=#{session_id} reason=#{inspect(reason)}, falling back to session-scoped team"
          )

          create_session_scoped_team(session_id, opts)
      end
    rescue
      e ->
        Logger.error(
          "[Kin:session] workspace attach FAILED session=#{session_id} error=#{inspect(e)}"
        )

        # Fallback: create a session-scoped team (backwards compatible)
        create_session_scoped_team(session_id, opts)
    end
  end

  # Fallback for when workspace server is unavailable
  defp create_session_scoped_team(session_id, opts) do
    project_path = Keyword.get(opts, :project_path)

    try do
      {:ok, team_id} =
        Loomkin.Teams.Manager.create_team(
          name: "session-#{String.slice(session_id, 0, 8)}",
          project_path: project_path
        )

      Logger.info("[Kin:session] fallback team created team=#{team_id} session=#{session_id}")
      persist_team_id(session_id, team_id)
      notify_session(session_id, {:team_created, team_id})
    rescue
      e ->
        Logger.error(
          "[Kin:session] fallback team FAILED session=#{session_id} error=#{inspect(e)}"
        )
    end
  end

  defp notify_session(session_id, message) do
    case Registry.lookup(Loomkin.SessionRegistry, session_id) do
      [{pid, _}] -> send(pid, message)
      [] -> :ok
    end
  end

  defp persist_team_id(session_id, team_id) do
    case Loomkin.Session.Persistence.get_session(session_id) do
      nil ->
        :ok

      db_session ->
        case Loomkin.Session.Persistence.update_session(db_session, %{team_id: team_id}) do
          {:ok, _} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  defp persist_workspace_id(session_id, workspace_id) do
    case Loomkin.Session.Persistence.get_session(session_id) do
      nil ->
        :ok

      db_session ->
        case Loomkin.Session.Persistence.update_session(db_session, %{workspace_id: workspace_id}) do
          {:ok, _} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  @doc """
  Stop a session gracefully.

  The team is NOT dissolved — it's owned by the workspace and persists
  across session disconnects. The session is detached from its workspace.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case find_session(session_id) do
      {:ok, pid} ->
        # Detach from workspace (best-effort — workspace may not exist)
        detach_from_workspace(session_id, pid)

        GenServer.stop(pid, :normal)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  defp detach_from_workspace(session_id, session_pid) do
    try do
      case Loomkin.Session.Persistence.get_session(session_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          if WorkspaceServer.alive?(workspace_id) do
            WorkspaceServer.detach_session(workspace_id, session_id)
          end

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    end

    # Legacy: dissolve team only if no workspace is managing it
    try do
      team_id = Session.get_team_id(session_pid)

      case Loomkin.Session.Persistence.get_session(session_id) do
        %{workspace_id: nil} when is_binary(team_id) ->
          Loomkin.Teams.Manager.dissolve_team(team_id)

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
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

  defp broadcast(session_id, {:team_available, _sid, team_id}) do
    signal =
      Loomkin.Signals.Session.TeamAvailable.new!(%{session_id: session_id, team_id: team_id})

    Loomkin.Signals.publish(signal)
  end
end
