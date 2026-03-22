defmodule Loomkin.Relay.Client do
  @moduledoc """
  GenServer managing the outbound WebSocket connection from the local daemon
  to the cloud relay.

  Connects via `:gun` to the relay Phoenix Channel, joins "daemon:lobby" with
  a Register payload, sends heartbeats on an interval, dispatches incoming
  commands to `CommandHandler`, and auto-reconnects with exponential backoff.
  """

  use GenServer

  require Logger

  alias Loomkin.Relay.Client.CommandHandler
  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Relay.Protocol.Register
  alias Loomkin.Relay.Protocol.WorkspaceUpdate

  defstruct [
    :gun_pid,
    :gun_ref,
    :ws_stream,
    :relay_url,
    :token,
    :heartbeat_interval_ms,
    :reconnect_base_ms,
    :reconnect_max_ms,
    status: :disconnected,
    reconnect_attempts: 0,
    heartbeat_timer: nil,
    last_heartbeat_ack: nil,
    join_ref: nil,
    msg_ref: 0,
    joined: false
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push an event to the cloud relay."
  @spec push_event(Event.t()) :: :ok | {:error, :not_connected}
  def push_event(%Event{} = event) do
    GenServer.cast(__MODULE__, {:push_event, event})
  end

  @doc "Push a workspace update to the cloud relay."
  @spec push_workspace_update(WorkspaceUpdate.t()) :: :ok | {:error, :not_connected}
  def push_workspace_update(%WorkspaceUpdate{} = update) do
    GenServer.cast(__MODULE__, {:push_workspace_update, update})
  end

  @doc "Get the current client status."
  @spec get_status() :: map()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    config = Application.get_env(:loomkin, __MODULE__, [])

    if config[:enabled] do
      state = %__MODULE__{
        relay_url: config[:relay_url],
        token: config[:token],
        heartbeat_interval_ms: config[:heartbeat_interval_ms] || 15_000,
        reconnect_base_ms: config[:reconnect_base_ms] || 1_000,
        reconnect_max_ms: config[:reconnect_max_ms] || 30_000
      }

      send(self(), :connect)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[Relay:client] connection failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  # Gun connection is up — upgrade to WebSocket
  def handle_info({:gun_up, pid, _protocol}, %{gun_pid: pid} = state) do
    path = ws_path(state)
    stream = :gun.ws_upgrade(pid, path, [], %{protocols: [{<<"websocket">>, :gun_ws_h}]})
    {:noreply, %{state | ws_stream: stream}}
  end

  # WebSocket upgrade succeeded
  def handle_info({:gun_upgrade, pid, stream, ["websocket"], _headers}, %{gun_pid: pid} = state) do
    Logger.info("[Relay:client] websocket connected")
    state = %{state | ws_stream: stream, status: :connected, reconnect_attempts: 0}

    # Join the daemon:lobby channel
    state = send_join(state)
    {:noreply, state}
  end

  # WebSocket upgrade failed
  def handle_info({:gun_response, pid, _stream, _fin, status, _headers}, %{gun_pid: pid} = state) do
    Logger.warning("[Relay:client] ws upgrade failed status=#{status}")
    cleanup_gun(state)
    {:noreply, schedule_reconnect(%{state | status: :disconnected, gun_pid: nil})}
  end

  def handle_info({:gun_error, pid, _stream, reason}, %{gun_pid: pid} = state) do
    Logger.warning("[Relay:client] gun error: #{inspect(reason)}")
    cleanup_gun(state)
    {:noreply, schedule_reconnect(%{state | status: :disconnected, gun_pid: nil})}
  end

  # WebSocket frame received
  def handle_info({:gun_ws, pid, _stream, {:text, data}}, %{gun_pid: pid} = state) do
    state = handle_ws_message(data, state)
    {:noreply, state}
  end

  # WebSocket closed
  def handle_info({:gun_ws, pid, _stream, :close}, %{gun_pid: pid} = state) do
    Logger.info("[Relay:client] websocket closed by server")
    cleanup_gun(state)
    {:noreply, schedule_reconnect(reset_connection(state))}
  end

  def handle_info({:gun_ws, pid, _stream, {:close, _code, _reason}}, %{gun_pid: pid} = state) do
    Logger.info("[Relay:client] websocket closed by server")
    cleanup_gun(state)
    {:noreply, schedule_reconnect(reset_connection(state))}
  end

  # Gun process went down
  def handle_info(
        {:gun_down, pid, _protocol, reason, _killed, _unprocessed},
        %{gun_pid: pid} = state
      ) do
    Logger.warning("[Relay:client] gun down: #{inspect(reason)}")
    {:noreply, schedule_reconnect(reset_connection(state))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{gun_ref: ref} = state) do
    Logger.warning("[Relay:client] gun process died: #{inspect(reason)}")
    {:noreply, schedule_reconnect(reset_connection(state))}
  end

  # Heartbeat timer
  def handle_info(:heartbeat, state) do
    if state.joined do
      state = push_channel_msg(state, "heartbeat", %{})
      timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
      {:noreply, %{state | heartbeat_timer: timer}}
    else
      {:noreply, state}
    end
  end

  # Reconnect timer
  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Casts ---

  @impl true
  def handle_cast({:push_event, %Event{} = event}, state) do
    if state.joined do
      state = push_channel_msg(state, "event", Event.to_map(event))
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:push_workspace_update, %WorkspaceUpdate{} = update}, state) do
    if state.joined do
      state = push_channel_msg(state, "workspace_update", WorkspaceUpdate.to_map(update))
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:push_response, response_map}, state) do
    if state.joined do
      state = push_channel_msg(state, "command_response", response_map)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_status, _from, state) do
    reply = %{
      status: state.status,
      joined: state.joined,
      reconnect_attempts: state.reconnect_attempts,
      last_heartbeat_ack: state.last_heartbeat_ack
    }

    {:reply, reply, state}
  end

  # --- Private: Connection ---

  defp do_connect(state) do
    uri = URI.parse(state.relay_url)
    host = String.to_charlist(uri.host || "localhost")
    port = uri.port || if(uri.scheme in ["wss", "https"], do: 443, else: 80)

    transport = if uri.scheme in ["wss", "https"], do: :tls, else: :tcp

    gun_opts = %{
      protocols: [:http],
      transport: transport,
      tls_opts: [verify: :verify_none]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case :gun.await_up(pid, 10_000) do
          {:ok, _protocol} ->
            {:ok, %{state | gun_pid: pid, gun_ref: ref, status: :connecting}}

          {:error, reason} ->
            :gun.close(pid)
            Process.demonitor(ref, [:flush])
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ws_path(state) do
    uri = URI.parse(state.relay_url)
    base = uri.path || "/relay/websocket"
    "#{base}?token=#{URI.encode_www_form(state.token || "")}&vsn=2.0.0"
  end

  defp cleanup_gun(%{gun_pid: nil}), do: :ok

  defp cleanup_gun(%{gun_pid: pid, gun_ref: ref}) do
    Process.demonitor(ref, [:flush])

    try do
      :gun.close(pid)
    catch
      _, _ -> :ok
    end
  end

  defp reset_connection(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    %{
      state
      | gun_pid: nil,
        gun_ref: nil,
        ws_stream: nil,
        status: :disconnected,
        joined: false,
        join_ref: nil,
        heartbeat_timer: nil
    }
  end

  defp schedule_reconnect(state) do
    delay =
      state.reconnect_base_ms
      |> Kernel.*(Integer.pow(2, min(state.reconnect_attempts, 10)))
      |> min(state.reconnect_max_ms)

    Logger.info(
      "[Relay:client] reconnecting in #{delay}ms (attempt #{state.reconnect_attempts + 1})"
    )

    Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_attempts: state.reconnect_attempts + 1}
  end

  # --- Private: Phoenix Channel Wire Protocol (v2 JSON) ---
  #
  # Phoenix v2 frames are JSON arrays: [join_ref, ref, topic, event, payload]

  defp send_join(state) do
    {state, join_ref} = next_ref(state)
    {state, ref} = next_ref(state)

    register = build_register()
    payload = Register.to_map(register) |> Map.delete("type")

    frame =
      Jason.encode!([to_string(join_ref), to_string(ref), "daemon:lobby", "phx_join", payload])

    :gun.ws_send(state.gun_pid, state.ws_stream, {:text, frame})

    %{state | join_ref: to_string(join_ref)}
  end

  defp push_channel_msg(state, event, payload) do
    {state, ref} = next_ref(state)

    frame =
      Jason.encode!([state.join_ref, to_string(ref), "daemon:lobby", event, payload])

    :gun.ws_send(state.gun_pid, state.ws_stream, {:text, frame})
    state
  end

  defp next_ref(state) do
    ref = state.msg_ref + 1
    {%{state | msg_ref: ref}, ref}
  end

  # --- Private: Handle incoming Phoenix channel messages ---

  defp handle_ws_message(data, state) do
    case Jason.decode(data) do
      {:ok, [_join_ref, _ref, _topic, event, payload]} ->
        handle_channel_event(event, payload, state)

      {:ok, _other} ->
        state

      {:error, _} ->
        Logger.warning("[Relay:client] failed to decode ws message")
        state
    end
  end

  defp handle_channel_event("phx_reply", %{"status" => "ok"} = _payload, state) do
    unless state.joined do
      Logger.info("[Relay:client] joined daemon:lobby")
      timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
      %{state | joined: true, heartbeat_timer: timer}
    else
      state
    end
  end

  defp handle_channel_event("phx_reply", %{"status" => status}, state) do
    Logger.warning("[Relay:client] channel reply status=#{status}")
    state
  end

  defp handle_channel_event("phx_error", _payload, state) do
    Logger.error("[Relay:client] channel error, will reconnect")
    cleanup_gun(state)
    schedule_reconnect(reset_connection(state))
  end

  defp handle_channel_event("phx_close", _payload, state) do
    Logger.info("[Relay:client] channel closed by server")
    cleanup_gun(state)
    schedule_reconnect(reset_connection(state))
  end

  defp handle_channel_event("command", payload, state) do
    command = Command.from_map(Map.put(payload, "type", "command"))

    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      response = CommandHandler.handle(command)
      response_map = Loomkin.Relay.Protocol.CommandResponse.to_map(response)

      GenServer.cast(__MODULE__, {:push_response, response_map})
    end)

    state
  end

  defp handle_channel_event("heartbeat_ack", _payload, state) do
    %{state | last_heartbeat_ack: DateTime.utc_now()}
  end

  defp handle_channel_event(event, _payload, state) do
    Logger.debug("[Relay:client] unhandled channel event: #{event}")
    state
  end

  # --- Private: Build Register payload ---

  defp build_register do
    workspaces = gather_workspaces()

    machine_name =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> to_string(node())
      end

    version = Application.spec(:loomkin, :vsn) |> to_string()

    %Register{
      machine_name: machine_name,
      version: version,
      workspaces: workspaces
    }
  end

  defp gather_workspaces do
    Registry.select(Loomkin.Workspace.Registry, [
      {{:"$1", :"$2", :_}, [], [%{id: :"$1", pid: :"$2"}]}
    ])
    |> Enum.flat_map(fn %{id: workspace_id, pid: pid} ->
      if Process.alive?(pid) do
        case Loomkin.Workspace.Server.get_state(workspace_id) do
          {:ok, ws_state} ->
            [
              %{
                id: workspace_id,
                name: ws_state.name || workspace_id,
                project_path: List.first(ws_state.project_paths || []) || "",
                team_id: ws_state.team_id,
                status: to_string(ws_state.status || :active),
                agent_count: count_agents(ws_state.team_id)
              }
            ]

          _ ->
            []
        end
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  defp count_agents(nil), do: 0

  defp count_agents(team_id) do
    team_id |> Loomkin.Teams.Manager.list_agents() |> length()
  rescue
    _ -> 0
  end
end
