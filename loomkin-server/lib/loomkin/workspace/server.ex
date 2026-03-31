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

  import Ecto.Query

  alias Loomkin.Collaboration
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
  def find_or_start(%{project_path: nil}), do: {:error, :no_project_path}
  def find_or_start(%{project_path: ""}), do: {:error, :no_project_path}

  def find_or_start(attrs) do
    project_path = Map.fetch!(attrs, :project_path)
    user_id = Map.get(attrs, :user_id)

    case find_by_project_path(project_path, user_id) do
      {:ok, workspace} ->
        ensure_started(workspace)

      :not_found ->
        name = Map.get(attrs, :name, Path.basename(project_path))

        workspace_attrs = %{
          name: name,
          project_paths: [project_path],
          status: :active
        }

        case create_workspace_with_owner(workspace_attrs, user_id) do
          {:ok, %{workspace: workspace}} ->
            ensure_started(workspace)

          {:error, :workspace, %Ecto.Changeset{} = changeset, _changes} ->
            if has_unique_constraint_error?(changeset) do
              # Another process won the race — retry lookup
              case find_by_project_path(project_path, user_id) do
                {:ok, workspace} -> ensure_started(workspace)
                :not_found -> {:error, :workspace_creation_conflict}
              end
            else
              {:error, changeset}
            end

          {:error, _step, reason, _changes} ->
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
  Atomically get-or-create a team for this workspace.

  If the workspace already has a team_id, returns it. Otherwise calls `create_fn`
  to create a new team (serialized through the GenServer to prevent races).
  """
  @spec get_or_create_team_id(String.t(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def get_or_create_team_id(workspace_id, create_fn) do
    GenServer.call(via(workspace_id), {:get_or_create_team_id, create_fn}, 30_000)
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
  def handle_call({:get_or_create_team_id, create_fn}, _from, state) do
    alias Loomkin.Teams.TableRegistry

    case state.team_id do
      team_id when is_binary(team_id) ->
        # Verify the ETS table still exists in TableRegistry.
        # After an app restart, TableRegistry state is lost but the workspace
        # DB record still has the old team_id. If the table is missing,
        # recreate it and re-insert the team metadata so agents can function.
        case TableRegistry.get_table(team_id) do
          {:ok, _ref} ->
            {:reply, {:ok, team_id}, state}

          {:error, :not_found} ->
            Logger.warning("[Workspace] ETS table missing for team=#{team_id}, recreating")

            project_path =
              case state.project_paths do
                [p | _] -> p
                _ -> nil
              end

            {:ok, ref} = TableRegistry.create_table(team_id)

            :ets.insert(
              ref,
              {:meta,
               %{
                 id: team_id,
                 name: state.name,
                 project_path: project_path,
                 parent_team_id: nil,
                 depth: 0,
                 created_at: DateTime.utc_now()
               }}
            )

            # Re-start nervous system processes and rehydrate keepers for the recovered team
            Loomkin.Teams.Manager.ensure_nervous_system(team_id)

            {:reply, {:ok, team_id}, state}
        end

      nil ->
        case create_fn.() do
          {:ok, team_id} ->
            state = %{state | team_id: team_id}
            persist_field(state.id, %{team_id: team_id})
            {:reply, {:ok, team_id}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:hibernate, _from, state) do
    Logger.info("[Workspace] hibernating workspace=#{state.id} team=#{state.team_id}")

    # Checkpoint current task states
    checkpoint_tasks(state)

    # Checkpoint all active agents before dissolving team
    checkpoint_agents(state)

    # Persist status BEFORE dissolving team — if dissolve_team crashes,
    # the workspace is still correctly marked hibernated and won't hand
    # out a dead team_id on next find_or_start.
    case persist_field(state.id, %{status: :hibernated, team_id: nil}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Workspace] hibernate persist failed workspace=#{state.id} error=#{inspect(reason)}, continuing"
        )
    end

    # Dissolve the team (stops all agents + cleans up ETS)
    if state.team_id do
      try do
        Loomkin.Teams.Manager.dissolve_team(state.team_id)
      rescue
        e ->
          Logger.warning(
            "[Workspace] dissolve_team failed workspace=#{state.id} team=#{state.team_id} error=#{inspect(e)}"
          )
      end
    end

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

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "[Workspace] stopping workspace=#{state.id} team=#{state.team_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  # --- Private ---

  defp via(workspace_id) do
    {:via, Registry, {Loomkin.Workspace.Registry, workspace_id}}
  end

  defp find_by_project_path(project_path, user_id) do
    query =
      Workspace
      |> where([w], ^project_path in w.project_paths)
      |> where([w], w.status in [:active, :hibernated])

    query =
      if user_id do
        where(query, [w], w.user_id == ^user_id)
      else
        query
      end

    case query
         |> order_by([w], desc: w.updated_at)
         |> limit(1)
         |> Repo.one() do
      nil -> :not_found
      workspace -> {:ok, workspace}
    end
  end

  defp create_workspace_with_owner(workspace_attrs, user_id) do
    Collaboration.create_workspace_with_owner(workspace_attrs, user_id)
  end

  defp ensure_started(workspace) do
    case Registry.lookup(Loomkin.Workspace.Registry, workspace.id) do
      [{pid, _}] ->
        {:ok, pid, workspace.id}

      [] ->
        case DynamicSupervisor.start_child(
               Loomkin.Workspace.Supervisor,
               {__MODULE__, workspace_id: workspace.id}
             ) do
          {:ok, pid} ->
            # Re-activate if hibernated — only after start_child succeeds
            if workspace.status == :hibernated do
              persist_field(workspace.id, %{status: :active})
            end

            {:ok, pid, workspace.id}

          {:error, {:already_started, pid}} ->
            {:ok, pid, workspace.id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp persist_field(workspace_id, attrs) do
    # Convert Ecto.Enum values to strings for update_all (bypasses schema casting)
    db_attrs =
      Enum.map(attrs, fn
        {:status, val} when is_atom(val) -> {:status, to_string(val)}
        pair -> pair
      end)

    {count, _} =
      Workspace
      |> where([w], w.id == ^workspace_id)
      |> Repo.update_all(set: db_attrs)

    if count == 0 do
      Logger.warning("[Workspace] persist_field: workspace not found id=#{workspace_id}")
    end

    :ok
  rescue
    e ->
      Logger.error(
        "[Workspace] persist_field failed id=#{workspace_id} attrs=#{inspect(attrs)} error=#{inspect(e)}"
      )

      {:error, e}
  end

  defp has_unique_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, meta}} -> meta[:constraint] == :unique
      _ -> false
    end)
  end

  defp checkpoint_tasks(state) do
    if state.team_id do
      try do
        tasks = Loomkin.Teams.Tasks.list_all(state.team_id)
        checkpointable = Enum.filter(tasks, &(&1.status in [:in_progress, :assigned, :pending]))

        Repo.transaction(fn ->
          Enum.each(checkpointable, fn task ->
            result_summary =
              if is_binary(task.result), do: String.slice(task.result, 0, 10_000), else: nil

            changeset =
              %TaskJournalEntry{}
              |> TaskJournalEntry.changeset(%{
                workspace_id: state.id,
                task_id: task.id,
                status: to_string(task.status),
                result_summary: result_summary,
                checkpoint_json: %{
                  title: task.title,
                  owner: task.owner,
                  priority: task.priority,
                  description: task.description
                }
              })

            case Repo.insert(changeset) do
              {:ok, _} ->
                :ok

              {:error, changeset} ->
                Logger.warning(
                  "[Workspace] checkpoint entry failed workspace=#{state.id} task=#{task.id} errors=#{inspect(changeset.errors)}"
                )

                Repo.rollback(:checkpoint_entry_failed)
            end
          end)
        end)
      rescue
        e ->
          Logger.warning(
            "[Workspace] checkpoint failed workspace=#{state.id} error=#{inspect(e)}"
          )
      end
    end
  end

  defp checkpoint_agents(state) do
    if state.team_id do
      try do
        agents = Loomkin.Teams.Manager.list_agents(state.team_id)

        Enum.each(agents, fn %{name: name, pid: pid} ->
          try do
            agent_state = :sys.get_state(pid, 5_000)
            essential = Loomkin.Teams.AgentState.extract_essential_state(agent_state)
            state_binary = Loomkin.Teams.AgentState.serialize(essential)

            iteration =
              case agent_state.paused_state do
                %{iteration: i} when is_integer(i) -> i
                _ -> 0
              end

            attrs = %{
              team_id: state.team_id,
              agent_name: to_string(name),
              session_id: agent_state.session_id,
              iteration: iteration,
              status: :hibernated,
              state_binary: state_binary,
              messages_snapshot: %{count: length(agent_state.messages)},
              task_context:
                if(agent_state.task,
                  do: Map.take(agent_state.task, [:id, :title, :description]),
                  else: nil
                )
            }

            case Loomkin.Checkpoints.create_checkpoint(attrs) do
              {:ok, _} ->
                Logger.info(
                  "[Workspace] agent checkpoint saved agent=#{name} workspace=#{state.id}"
                )

              {:error, changeset} ->
                Logger.warning(
                  "[Workspace] agent checkpoint failed agent=#{name} errors=#{inspect(changeset.errors)}"
                )
            end
          catch
            :exit, reason ->
              Logger.warning(
                "[Workspace] agent checkpoint skipped agent=#{name} reason=#{inspect(reason)}"
              )
          end
        end)
      rescue
        e ->
          Logger.warning(
            "[Workspace] agent checkpoint failed workspace=#{state.id} error=#{inspect(e)}"
          )
      end
    end
  end
end
