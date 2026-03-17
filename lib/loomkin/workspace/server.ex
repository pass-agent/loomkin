defmodule Loomkin.Workspace.Server do
  @moduledoc """
  GenServer that owns team lifetime for a workspace.

  Starts when a session connects to a project. Persists across session
  disconnects so agents keep running. Provides hibernate/1 for explicit
  shutdown with checkpoint.

  ## Lifecycle

      session connects → find_or_create workspace → Server starts
      session disconnects → Server + team stay alive
      hibernate/1 called → checkpoint state → dissolve team → stop Server
  """

  use GenServer

  require Logger

  alias Loomkin.Repo
  alias Loomkin.Workspace
  alias Loomkin.Workspace.TaskJournalEntry

  defstruct [
    :id,
    :name,
    :team_id,
    :status,
    project_paths: [],
    session_ids: MapSet.new()
  ]

  # --- Public API ---

  @doc "Start a workspace server for the given workspace record."
  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    GenServer.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  @doc "Find or start a workspace server, creating the DB record if needed."
  @spec find_or_start(map()) :: {:ok, pid(), String.t()} | {:error, term()}
  def find_or_start(attrs) do
    project_path = Map.fetch!(attrs, :project_path)

    case find_by_project_path(project_path) do
      {:ok, workspace} ->
        ensure_started(workspace)

      :not_found ->
        name = Map.get(attrs, :name, Path.basename(project_path))
        user_id = Map.get(attrs, :user_id)

        case create_workspace(%{
               name: name,
               project_paths: [project_path],
               status: :active,
               user_id: user_id
             }) do
          {:ok, workspace} ->
            ensure_started(workspace)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Attach a session to this workspace."
  @spec attach_session(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_session(workspace_id, session_id) do
    GenServer.call(via(workspace_id), {:attach_session, session_id})
  end

  @doc "Detach a session from this workspace. Team keeps running."
  @spec detach_session(String.t(), String.t()) :: :ok
  def detach_session(workspace_id, session_id) do
    GenServer.call(via(workspace_id), {:detach_session, session_id})
  end

  @doc "Get the team_id for this workspace."
  @spec get_team_id(String.t()) :: String.t() | nil
  def get_team_id(workspace_id) do
    GenServer.call(via(workspace_id), :get_team_id)
  end

  @doc "Set the team_id for this workspace (called when team is first created)."
  @spec set_team_id(String.t(), String.t()) :: :ok
  def set_team_id(workspace_id, team_id) do
    GenServer.call(via(workspace_id), {:set_team_id, team_id})
  end

  @doc """
  Hibernate the workspace — checkpoint state, dissolve team, stop server.

  This is an explicit shutdown. The workspace can be resumed later by
  calling find_or_start/1 with the same project_path.
  """
  @spec hibernate(String.t()) :: :ok | {:error, term()}
  def hibernate(workspace_id) do
    GenServer.call(via(workspace_id), :hibernate, 30_000)
  end

  @doc "Get the current state of a workspace server."
  @spec get_state(String.t()) :: {:ok, map()} | {:error, term()}
  def get_state(workspace_id) do
    GenServer.call(via(workspace_id), :get_state)
  end

  @doc "Record a task journal entry for this workspace."
  @spec journal_task(String.t(), map()) :: {:ok, TaskJournalEntry.t()} | {:error, term()}
  def journal_task(workspace_id, attrs) do
    GenServer.call(via(workspace_id), {:journal_task, attrs})
  end

  @doc "Check if a workspace server is running."
  @spec alive?(String.t()) :: boolean()
  def alive?(workspace_id) do
    case Registry.lookup(Loomkin.Workspace.Registry, workspace_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    case Repo.get(Workspace, workspace_id) do
      nil ->
        {:stop, :workspace_not_found}

      workspace ->
        Logger.info("[Workspace] started id=#{workspace_id} name=#{workspace.name}")

        state = %__MODULE__{
          id: workspace.id,
          name: workspace.name,
          team_id: workspace.team_id,
          status: workspace.status,
          project_paths: workspace.project_paths || []
        }

        {:ok, state}
    end
  end

  @impl true
  def handle_call({:attach_session, session_id}, _from, state) do
    state = %{state | session_ids: MapSet.put(state.session_ids, session_id)}

    Logger.info(
      "[Workspace] session attached workspace=#{state.id} session=#{session_id} count=#{MapSet.size(state.session_ids)}"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:detach_session, session_id}, _from, state) do
    state = %{state | session_ids: MapSet.delete(state.session_ids, session_id)}

    Logger.info(
      "[Workspace] session detached workspace=#{state.id} session=#{session_id} count=#{MapSet.size(state.session_ids)}"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_team_id, _from, state) do
    {:reply, state.team_id, state}
  end

  @impl true
  def handle_call({:set_team_id, team_id}, _from, state) do
    state = %{state | team_id: team_id}
    persist_field(state.id, %{team_id: team_id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:hibernate, _from, state) do
    Logger.info("[Workspace] hibernating workspace=#{state.id} team=#{state.team_id}")

    # Checkpoint current task states
    checkpoint_tasks(state)

    # Dissolve the team (stops all agents + cleans up ETS)
    if state.team_id do
      Loomkin.Teams.Manager.dissolve_team(state.team_id)
    end

    # Update DB status
    persist_field(state.id, %{status: :hibernated})

    {:stop, :normal, :ok, %{state | status: :hibernated, team_id: nil}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      id: state.id,
      name: state.name,
      team_id: state.team_id,
      status: state.status,
      project_paths: state.project_paths,
      session_count: MapSet.size(state.session_ids)
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_call({:journal_task, attrs}, _from, state) do
    result =
      %TaskJournalEntry{}
      |> TaskJournalEntry.changeset(Map.put(attrs, :workspace_id, state.id))
      |> Repo.insert()

    {:reply, result, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Workspace] unhandled message workspace=#{state.id} msg=#{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  defp via(workspace_id) do
    {:via, Registry, {Loomkin.Workspace.Registry, workspace_id}}
  end

  defp find_by_project_path(project_path) do
    import Ecto.Query

    case Workspace
         |> where([w], ^project_path in w.project_paths)
         |> where([w], w.status in [:active, :hibernated])
         |> order_by([w], desc: w.updated_at)
         |> limit(1)
         |> Repo.one() do
      nil -> :not_found
      workspace -> {:ok, workspace}
    end
  end

  defp create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_started(workspace) do
    case Registry.lookup(Loomkin.Workspace.Registry, workspace.id) do
      [{pid, _}] ->
        {:ok, pid, workspace.id}

      [] ->
        # Re-activate if hibernated
        if workspace.status == :hibernated do
          persist_field(workspace.id, %{status: :active})
        end

        case DynamicSupervisor.start_child(
               Loomkin.Workspace.Supervisor,
               {__MODULE__, workspace_id: workspace.id}
             ) do
          {:ok, pid} -> {:ok, pid, workspace.id}
          {:error, {:already_started, pid}} -> {:ok, pid, workspace.id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp persist_field(workspace_id, attrs) do
    case Repo.get(Workspace, workspace_id) do
      nil -> :ok
      workspace -> workspace |> Workspace.changeset(attrs) |> Repo.update()
    end
  end

  defp checkpoint_tasks(state) do
    if state.team_id do
      try do
        tasks = Loomkin.Teams.Tasks.list_all(state.team_id)

        for task <- tasks, task.status in [:in_progress, :assigned, :pending] do
          %TaskJournalEntry{}
          |> TaskJournalEntry.changeset(%{
            workspace_id: state.id,
            task_id: task.id,
            status: to_string(task.status),
            result_summary: task.result,
            checkpoint_json: %{
              title: task.title,
              owner: task.owner,
              priority: task.priority,
              description: task.description
            }
          })
          |> Repo.insert()
        end
      rescue
        e ->
          Logger.warning(
            "[Workspace] checkpoint failed workspace=#{state.id} error=#{inspect(e)}"
          )
      end
    end
  end
end
