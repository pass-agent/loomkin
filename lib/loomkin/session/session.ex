defmodule Loomkin.Session do
  @moduledoc "Core GenServer that runs the agent loop for a coding assistant session."

  use GenServer

  alias Loomkin.Session.Architect
  alias Loomkin.Session.Persistence

  require Logger

  defstruct [
    :id,
    :model,
    :fast_model,
    :project_path,
    :db_session,
    :status,
    :team_id,
    :pending_permission,
    :architect_task,
    messages: [],
    tools: [],
    auto_approve: false,
    child_team_ids: [],
    bootstrap_spawned: false
  ]

  # --- Public API ---

  @doc "Subscribe to session events via PubSub."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "session:#{session_id}")
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Loomkin.SessionRegistry, session_id, :idle}}
    )
  end

  @doc "Send a user message and get back the assistant's response."
  @spec send_message(pid() | String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  def send_message(session_id, text) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> send_message(pid, text)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the conversation history."
  @spec get_history(pid() | String.t()) :: {:ok, [map()]}
  def get_history(pid) when is_pid(pid) do
    GenServer.call(pid, :get_history)
  end

  def get_history(session_id) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_history(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Update the model for a running session."
  @spec update_model(pid() | String.t(), String.t()) :: :ok | {:error, term()}
  def update_model(pid, model) when is_pid(pid) do
    GenServer.call(pid, {:update_model, model})
  end

  def update_model(session_id, model) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> update_model(pid, model)
      :error -> {:error, :not_found}
    end
  end

  @doc "Update the fast model for a running session."
  @spec update_fast_model(pid() | String.t(), String.t()) :: :ok | {:error, term()}
  def update_fast_model(pid, model) when is_pid(pid) do
    GenServer.call(pid, {:update_fast_model, model})
  end

  def update_fast_model(session_id, model) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> update_fast_model(pid, model)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current session status."
  @spec get_status(pid() | String.t()) :: {:ok, atom()}
  def get_status(pid) when is_pid(pid) do
    GenServer.call(pid, :get_status, 15_000)
  end

  def get_status(session_id) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_status(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Cancel the currently running agent task."
  @spec cancel(pid() | String.t()) :: :ok | {:error, term()}
  def cancel(pid) when is_pid(pid) do
    GenServer.call(pid, :cancel)
  end

  def cancel(session_id) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> cancel(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current model for a running session."
  @spec get_model(pid()) :: String.t()
  def get_model(pid) when is_pid(pid) do
    GenServer.call(pid, :get_model, 5_000)
  end

  @doc "Get the current fast model for a running session."
  @spec get_fast_model(pid()) :: String.t()
  def get_fast_model(pid) when is_pid(pid) do
    GenServer.call(pid, :get_fast_model, 5_000)
  end

  @doc "Get the team_id for a running session."
  @spec get_team_id(pid()) :: String.t() | nil
  def get_team_id(pid) when is_pid(pid) do
    GenServer.call(pid, :get_team_id, 5_000)
  end

  @doc "Update the project path for a running session."
  @spec update_project_path(pid() | String.t(), String.t()) :: :ok | {:error, term()}
  def update_project_path(pid, path) when is_pid(pid) do
    GenServer.call(pid, {:update_project_path, path})
  end

  def update_project_path(session_id, path) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> update_project_path(pid, path)
      :error -> {:error, :not_found}
    end
  end

  @doc "Send a permission response to the session."
  def permission_response(session_id, action, tool_name, tool_path) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> GenServer.cast(pid, {:permission_response, action, tool_name, tool_path})
      :error -> {:error, :not_found}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    model = Keyword.get(opts, :model, default_model())
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    title = Keyword.get(opts, :title)
    tools = Keyword.get(opts, :tools, [])

    auto_approve = Keyword.get(opts, :auto_approve, false)

    fast_model = Keyword.get(opts, :fast_model)

    case load_or_create_session(session_id, model, project_path, title) do
      {:ok, db_session, messages} ->
        # Prefer the DB-persisted model for resumed sessions so the user's
        # last selection survives page refreshes — but only if the provider
        # is actually available (has API key or OAuth). Stale sessions may
        # reference providers the user never configured.
        effective_model = validate_model(db_session.model, model)
        effective_fast_model = validate_model(db_session.fast_model, fast_model || effective_model)

        state = %__MODULE__{
          id: db_session.id,
          model: effective_model,
          fast_model: effective_fast_model,
          project_path: project_path,
          db_session: db_session,
          messages: messages,
          status: :idle,
          tools: tools,
          auto_approve: auto_approve
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, text}, from, state) do
    Logger.debug("[Session] send_message session=#{state.id} model=#{state.model}")

    # Spawn bootstrap agents on first message (deferred from session start)
    state = maybe_spawn_bootstrap_agents(state)

    # Try routing to Concierge first (bootstrap agent pattern)
    case maybe_route_to_concierge(state, text) do
      {:routed, concierge_pid} ->
        # Persist and broadcast the user message
        {:ok, _} =
          Persistence.save_message(%{session_id: state.id, role: :user, content: text})

        user_msg = %{role: :user, content: text}
        state = %{state | messages: state.messages ++ [user_msg]}
        broadcast(state.id, {:new_message, state.id, user_msg})

        state = update_status(state, :thinking)

        # Run concierge call in an async Task so the Session stays responsive
        session_id = state.id

        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            case Loomkin.Teams.Agent.send_message(concierge_pid, text) do
              {:ok, response_text} ->
                # Persist and broadcast the assistant response
                {:ok, _} =
                  Persistence.save_message(%{
                    session_id: session_id,
                    role: :assistant,
                    content: response_text
                  })

                assistant_msg = %{role: :assistant, content: response_text, from: "concierge"}
                broadcast(session_id, {:new_message, session_id, assistant_msg})
                {:ok, response_text, assistant_msg}

              {:error, reason} ->
                {:error, reason}
            end
          end)

        {:noreply, %{state | architect_task: {task, from}}}

      :not_routed ->
        state = update_status(state, :thinking)

        # Run architect in an async Task so the GenServer stays responsive
        # for permission responses while the architect is running.
        task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            Architect.run(text, state, architect_model: state.model)
          end)

        {:noreply, %{state | architect_task: {task, from}}}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call({:update_model, model}, _from, state) do
    Persistence.update_session(state.db_session, %{model: model})
    {:reply, :ok, %{state | model: model}}
  end

  @impl true
  def handle_call({:update_fast_model, model}, _from, state) do
    Persistence.update_session(state.db_session, %{fast_model: model})
    {:reply, :ok, %{state | fast_model: model}}
  end

  @impl true
  def handle_call(:get_fast_model, _from, state) do
    {:reply, state.fast_model, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:get_model, _from, state) do
    {:reply, state.model, state}
  end

  @impl true
  def handle_call(:get_team_id, _from, state) do
    {:reply, Map.get(state, :team_id), state}
  end

  @impl true
  def handle_call({:update_project_path, path}, _from, state) do
    Logger.debug("[Session] Updated project_path to #{path}")
    Persistence.update_session(state.db_session, %{project_path: path})
    {:reply, :ok, %{state | project_path: path}}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    case state.architect_task do
      {%Task{} = task, from} ->
        Logger.info("[Session] Cancelling agent task for session=#{state.id}")
        Task.shutdown(task, :brutal_kill)
        GenServer.reply(from, {:error, :cancelled})
        broadcast(state.id, {:session_cancelled, state.id})
        state = %{state | architect_task: nil}
        state = update_status(state, :idle)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_task_running}, state}
    end
  end

  # --- handle_info ---

  @impl true
  def handle_info({:team_created, team_id}, state) do
    Logger.info(
      "[Session] :team_created received team_id=#{team_id} session=#{state.id} — broadcasting :team_available"
    )

    broadcast(state.id, {:team_available, state.id, team_id})
    {:noreply, Map.put(state, :team_id, team_id)}
  end

  @impl true
  def handle_info({:child_team_created, child_team_id}, state) do
    Logger.info("[Session] Child team created: #{child_team_id} for session #{state.id}")
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{child_team_id}:tasks")
    child_ids = [child_team_id | state.child_team_ids] |> Enum.uniq()
    broadcast(state.id, {:child_team_available, state.id, child_team_id})
    {:noreply, %{state | child_team_ids: child_ids}}
  end

  @impl true
  def handle_info({:task_completed, _task_id, _agent_name, _result} = event, state) do
    # Check if this completion means all tasks in a child team are done
    check_child_team_completion(state, event)
    {:noreply, state}
  end

  # --- Async Architect Task completion ---

  # Concierge route: Task returns {:ok, response_text, assistant_msg} (just the new message)
  @impl true
  def handle_info({ref, {:ok, response_text, %{role: _} = assistant_msg}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.architect_task do
      {%Task{ref: ^ref}, from} ->
        Logger.info("[Session] Concierge call succeeded session=#{state.id}")
        state = %{state | messages: state.messages ++ [assistant_msg], architect_task: nil}
        state = update_status(state, :idle)
        GenServer.reply(from, {:ok, response_text})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Architect route: Task returns {:ok, response_text, updated_state}
  @impl true
  def handle_info({ref, {:ok, response_text, %__MODULE__{} = new_state}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.architect_task do
      {%Task{ref: ^ref}, from} ->
        Logger.info("[Session] Architect.run succeeded session=#{state.id}")
        state = %{state | messages: new_state.messages, architect_task: nil}
        state = update_status(state, :idle)
        GenServer.reply(from, {:ok, response_text})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Concierge error: Task returns {:error, reason} (no state)
  @impl true
  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.architect_task do
      {%Task{ref: ^ref}, from} ->
        Logger.error("[Session] Async task failed session=#{state.id}: #{inspect(reason)}")
        broadcast(state.id, {:llm_error, state.id, format_error(reason)})
        state = %{state | architect_task: nil}
        state = update_status(state, :idle)
        GenServer.reply(from, {:error, reason})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Architect error: Task returns {:error, reason, updated_state}
  @impl true
  def handle_info({ref, {:error, reason, new_state}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.architect_task do
      {%Task{ref: ^ref}, from} ->
        Logger.error("[Session] Architect.run failed session=#{state.id}: #{inspect(reason)}")
        broadcast(state.id, {:llm_error, state.id, format_error(reason)})
        state = %{state | messages: new_state.messages, architect_task: nil}
        state = update_status(state, :idle)
        GenServer.reply(from, {:error, reason})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Handle architect Task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case state.architect_task do
      {%Task{ref: ^ref}, from} ->
        Logger.error("[Session] Architect task crashed: #{inspect(reason)}")
        broadcast(state.id, {:llm_error, state.id, "Architect crashed: #{inspect(reason)}"})
        state = %{state | architect_task: nil}
        state = update_status(state, :idle)
        GenServer.reply(from, {:error, :crashed})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # --- Permission pending from Architect Task ---

  @impl true
  def handle_info({:permission_pending, architect_pid, tool_name, tool_path}, state) do
    Logger.debug("[Session] Permission pending: #{tool_name} #{tool_path}")

    {:noreply,
     %{state | pending_permission: {architect_pid, %{tool_name: tool_name, tool_path: tool_path}}}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Permission response from LiveView ---

  @impl true
  def handle_cast({:permission_response, action, tool_name, tool_path}, state) do
    case state.pending_permission do
      nil ->
        {:noreply, state}

      {architect_pid, _pending_info} ->
        if action == "allow_always" do
          Loomkin.Permissions.Manager.grant(tool_name, tool_path, state.id)
        end

        tool_result =
          if action in ["allow_once", "allow_always"],
            do: nil,
            else: "Error: Permission denied for #{tool_name}"

        send(architect_pid, {:permission_decision, action, tool_name, tool_result})
        {:noreply, %{state | pending_permission: nil}}
    end
  end

  # --- Private ----------------------------------------

  defp load_or_create_session(session_id, model, project_path, title) do
    case Persistence.get_session(session_id) do
      nil ->
        # Create new session
        attrs = %{
          id: session_id,
          model: model,
          project_path: project_path,
          title: title || "Session #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")}"
        }

        case Persistence.create_session(attrs) do
          {:ok, db_session} ->
            {:ok, db_session, []}

          {:error, changeset} ->
            {:error, changeset}
        end

      db_session ->
        # Resume existing session
        messages =
          Persistence.load_messages(session_id)
          |> Enum.map(&db_message_to_map/1)

        {:ok, db_session, messages}
    end
  end

  defp db_message_to_map(msg) do
    base = %{role: msg.role, content: msg.content}

    base =
      if msg.tool_calls do
        Map.put(base, :tool_calls, msg.tool_calls)
      else
        base
      end

    if msg.tool_call_id do
      Map.put(base, :tool_call_id, msg.tool_call_id)
    else
      base
    end
  end

  defp update_status(state, new_status) do
    # Update registry metadata
    if state.id do
      Registry.update_value(Loomkin.SessionRegistry, state.id, fn _ -> new_status end)
    end

    broadcast(state.id, {:session_status, state.id, new_status})

    %{state | status: new_status}
  end

  defp default_model do
    Application.get_env(:loomkin, :default_model, "zai:glm-5")
  end

  # Validate a persisted model string — fall back if the provider isn't available.
  defp validate_model(nil, fallback), do: fallback

  defp validate_model(model, fallback) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model_id] ->
        provider_atom = String.to_existing_atom(provider)

        case Loomkin.Models.api_key_status(provider_atom) do
          {:set, _} -> model
          {:oauth, :connected} -> model
          _ ->
            Logger.warning("[Session] Persisted model #{model} unavailable — falling back to #{fallback}")
            fallback
        end

      _ ->
        model
    end
  rescue
    ArgumentError ->
      # Provider atom doesn't exist — unknown provider
      Logger.warning("[Session] Unknown provider in model #{model} — falling back to #{fallback}")
      fallback
  end

  defp check_child_team_completion(state, _event) do
    for child_team_id <- state.child_team_ids do
      tasks = Loomkin.Teams.Tasks.list_all(child_team_id)

      if tasks != [] && Enum.all?(tasks, fn t -> t.status in [:completed, :failed] end) do
        results =
          tasks
          |> Enum.filter(fn t -> t.status == :completed end)
          |> Enum.map(fn t -> "- **#{t.title}**: #{t.result || "done"}" end)
          |> Enum.join("\n")

        failed =
          tasks
          |> Enum.filter(fn t -> t.status == :failed end)
          |> Enum.map(fn t -> "- **#{t.title}**: #{t.result || "failed"}" end)
          |> Enum.join("\n")

        summary = """
        ## Team Results

        #{if results != "", do: "### Completed\n#{results}\n", else: ""}#{if failed != "", do: "### Failed\n#{failed}\n", else: ""}
        """

        msg = %{role: :assistant, content: String.trim(summary), from: "Team"}

        Persistence.save_message(%{
          session_id: state.id,
          role: :assistant,
          content: String.trim(summary)
        })

        broadcast(state.id, {:new_message, state.id, msg})
        Logger.info("[Session] Child team #{child_team_id} completed — results sent to chat")
      end
    end
  rescue
    e ->
      Logger.error("[Session] Error checking child team completion: #{Exception.message(e)}")
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Loomkin.PubSub, "session:#{session_id}", event)
  rescue
    e -> Logger.warning("[Session] Broadcast failed: #{Exception.message(e)}")
  end

  defp maybe_spawn_bootstrap_agents(%{bootstrap_spawned: true} = state), do: state

  defp maybe_spawn_bootstrap_agents(%{team_id: nil} = state), do: state

  defp maybe_spawn_bootstrap_agents(state) do
    team_id = state.team_id
    project_path = state.project_path

    Logger.info(
      "[Session] Spawning bootstrap agents on first message team=#{team_id} path=#{project_path}"
    )

    # Spawn Concierge (thinking model)
    case Loomkin.Teams.Manager.spawn_agent(team_id, "concierge", :concierge,
           model: state.model,
           project_path: project_path
         ) do
      {:ok, pid} ->
        Logger.info("[Session] Concierge spawned pid=#{inspect(pid)} team=#{team_id}")

      {:error, reason} ->
        Logger.warning("[Session] Concierge FAILED team=#{team_id}: #{inspect(reason)}")
    end

    # Spawn Orienter (fast model)
    fast_model = state.fast_model || state.model

    case Loomkin.Teams.Manager.spawn_agent(team_id, "orienter", :orienter,
           model: fast_model,
           project_path: project_path
         ) do
      {:ok, pid} ->
        Logger.info("[Session] Orienter spawned pid=#{inspect(pid)} team=#{team_id}")

      {:error, reason} ->
        Logger.warning("[Session] Orienter FAILED team=#{team_id}: #{inspect(reason)}")
    end

    %{state | bootstrap_spawned: true}
  end

  defp maybe_route_to_concierge(state, _text) do
    with team_id when is_binary(team_id) <- state.team_id,
         {:ok, pid} <- Loomkin.Session.Manager.find_agent(team_id, "concierge") do
      {:routed, pid}
    else
      _ -> :not_routed
    end
  end

  defp format_error(%{reason: reason, status: status}) when is_binary(reason) do
    if status, do: "[#{status}] #{reason}", else: reason
  end

  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
