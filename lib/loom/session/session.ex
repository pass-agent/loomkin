defmodule Loom.Session do
  @moduledoc "Core GenServer that runs the agent loop for a coding assistant session."

  use GenServer

  alias Loom.Session.{Architect, Persistence}

  require Logger

  defstruct [
    :id,
    :model,
    :project_path,
    :db_session,
    :status,
    :team_id,
    messages: [],
    tools: [],
    auto_approve: false
  ]

  # --- Public API ---

  @doc "Subscribe to session events via PubSub."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Loom.PubSub, "session:#{session_id}")
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Loom.SessionRegistry, session_id, :idle}}
    )
  end

  @doc "Send a user message and get back the assistant's response."
  @spec send_message(pid() | String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  def send_message(session_id, text) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
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
    case Loom.Session.Manager.find_session(session_id) do
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
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> update_model(pid, model)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current session status."
  @spec get_status(pid() | String.t()) :: {:ok, atom()}
  def get_status(pid) when is_pid(pid) do
    GenServer.call(pid, :get_status)
  end

  def get_status(session_id) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_status(pid)
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

    case load_or_create_session(session_id, model, project_path, title) do
      {:ok, db_session, messages} ->
        state = %__MODULE__{
          id: db_session.id,
          model: model,
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
  def handle_call({:send_message, text}, _from, state) do
    Logger.info("[Session] send_message session=#{state.id} model=#{state.model} text=#{String.slice(text, 0, 100)}")
    state = update_status(state, :thinking)

    # Always use architect mode — plan with primary model, execute with
    # secondary model only when the user has explicitly configured one.
    case Architect.run(text, state, architect_model: state.model) do
      {:ok, response_text, state} ->
        Logger.info("[Session] Architect.run succeeded session=#{state.id}")
        state = update_status(state, :idle)
        {:reply, {:ok, response_text}, state}

      {:error, reason, state} ->
        Logger.error("[Session] Architect.run failed session=#{state.id}: #{inspect(reason)}")
        state = update_status(state, :idle)
        {:reply, {:error, reason}, state}
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
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:get_team_id, _from, state) do
    {:reply, state.team_id, state}
  end

  # --- handle_info ---

  @impl true
  def handle_info({:team_created, team_id}, state) do
    Logger.info("[Session] Backing team created: #{team_id} for session #{state.id}")
    broadcast(state.id, {:team_available, state.id, team_id})
    {:noreply, %{state | team_id: team_id}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
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
      Registry.update_value(Loom.SessionRegistry, state.id, fn _ -> new_status end)
    end

    broadcast(state.id, {:session_status, state.id, new_status})

    %{state | status: new_status}
  end

  defp default_model do
    Application.get_env(:loom, :default_model, "anthropic:claude-sonnet-4-6")
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Loom.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
