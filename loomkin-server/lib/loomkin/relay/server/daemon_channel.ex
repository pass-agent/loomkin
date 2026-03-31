defmodule Loomkin.Relay.Server.DaemonChannel do
  @moduledoc """
  Phoenix.Channel that handles all daemon-to-cloud communication.

  Joined as "daemon:<workspace_id>". On join the daemon sends its register
  payload to announce workspaces. Subsequent messages handle heartbeats,
  command responses, events, and workspace updates.

  Authorization is enforced in two layers:
  1. **Join**: the topic workspace_id must match the token's workspace_id
  2. **Commands**: role-based access control limits what actions each role
     can perform (observer < collaborator < owner)
  """

  use Phoenix.Channel

  alias Loomkin.Relay.Protocol.CommandResponse
  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Relay.Protocol.HeartbeatAck
  alias Loomkin.Relay.Protocol.Register
  alias Loomkin.Relay.Protocol.WorkspaceUpdate
  alias Loomkin.Relay.Server.Registry

  require Logger

  # Commands grouped by minimum role required
  @observer_commands ~w(get_status get_history get_agents)
  @collaborator_commands @observer_commands ++
                           ~w(send_message approve_tool deny_tool pause_agent resume_agent)
  @owner_commands @collaborator_commands ++ ~w(kill_team change_model steer_agent cancel)

  # --- Join ---

  @impl true
  def join("daemon:" <> workspace_id, params, socket) do
    if workspace_id == socket.assigns.workspace_id do
      register = Register.from_map(Map.put(params, "type", "register"))
      user_id = socket.assigns.user_id
      role = socket.assigns.role
      now = DateTime.utc_now()

      # Evict stale entries from previous connections for this user
      Registry.evict_stale_workspaces(user_id, self())

      for ws <- register.workspaces do
        Registry.register_workspace(user_id, ws.id, %{
          channel_pid: self(),
          machine_name: register.machine_name,
          status: ws.status,
          team_id: ws.team_id,
          agent_count: ws.agent_count,
          last_heartbeat: now,
          project_path: ws.project_path,
          workspace_name: ws.name
        })
      end

      socket =
        socket
        |> assign(:machine_name, register.machine_name)
        |> assign(:version, register.version)
        |> assign(:workspace_ids, Enum.map(register.workspaces, & &1.id))
        |> assign(:role, role)

      Logger.info(
        "Daemon joined: user=#{user_id} workspace=#{workspace_id} role=#{role} machine=#{register.machine_name} workspaces=#{length(register.workspaces)}"
      )

      {:ok, socket}
    else
      {:error, %{reason: "workspace_id mismatch"}}
    end
  end

  # --- Incoming messages ---

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    user_id = socket.assigns.user_id

    for ws_id <- socket.assigns.workspace_ids do
      Registry.update_heartbeat(user_id, ws_id)
    end

    ack =
      HeartbeatAck.to_map(%HeartbeatAck{timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

    {:reply, {:ok, ack}, socket}
  end

  def handle_in("command_response", payload, socket) do
    response = CommandResponse.from_map(Map.put(payload, "type", "command_response"))

    case Elixir.Registry.lookup(Loomkin.Relay.PendingCommands, response.request_id) do
      [{caller_pid, _value}] ->
        send(caller_pid, {:command_response, response})

      [] ->
        Logger.warning("No pending caller for command_response request_id=#{response.request_id}")
    end

    {:noreply, socket}
  end

  def handle_in("event", payload, socket) do
    event = Event.from_map(Map.put(payload, "type", "event"))

    if event.workspace_id in socket.assigns.workspace_ids do
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "relay:events:#{event.workspace_id}",
        {:relay_event, event}
      )
    else
      Logger.warning(
        "DaemonChannel: event workspace_id=#{event.workspace_id} not in owned workspaces"
      )
    end

    {:noreply, socket}
  end

  def handle_in("workspace_update", payload, socket) do
    update = WorkspaceUpdate.from_map(Map.put(payload, "type", "workspace_update"))
    user_id = socket.assigns.user_id

    if update.workspace_id in socket.assigns.workspace_ids do
      changes = %{
        status: update.status,
        agent_count: update.agent_count
      }

      changes =
        changes
        |> maybe_put(:workspace_name, update.name)
        |> maybe_put(:project_path, update.project_path)
        |> maybe_put(:team_id, update.team_id)

      Registry.update_workspace(user_id, update.workspace_id, changes)

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "relay:workspaces:#{user_id}",
        {:workspace_update, update}
      )
    else
      Logger.warning(
        "DaemonChannel: workspace_update for unowned workspace_id=#{update.workspace_id}"
      )
    end

    {:noreply, socket}
  end

  # Daemon-initiated command request: the daemon asks the relay whether its
  # role is authorized for a given action. This is NOT the relay pushing a
  # command to the daemon (that flow goes through handle_info({:push_command, ...})).
  # The trust boundary is: the relay validates the daemon's role claim (set at
  # socket connect time from the macaroon token) and returns accepted/rejected.
  def handle_in("command_request", payload, socket) do
    action = payload["action"]
    role = socket.assigns.role

    if authorized?(role, action) do
      {:reply, {:ok, %{"accepted" => true}}, socket}
    else
      {:reply, {:error, %{"reason" => "role '#{role}' is not authorized for action '#{action}'"}},
       socket}
    end
  end

  def handle_in(unknown, _payload, socket) do
    Logger.warning("DaemonChannel received unknown message type: #{unknown}")
    {:noreply, socket}
  end

  # --- Sending commands to daemon ---

  @doc """
  Send a command to the daemon channel for a given user's workspace.

  Registers the caller in PendingCommands so the response can be routed back.
  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec send_command(integer(), String.t(), Loomkin.Relay.Protocol.Command.t(), timeout()) ::
          {:ok, CommandResponse.t()} | {:error, :not_connected | :timeout}
  def send_command(user_id, workspace_id, command, timeout \\ 30_000) do
    case Registry.lookup_workspace(user_id, workspace_id) do
      {:ok, %{channel_pid: pid}} ->
        case Elixir.Registry.register(Loomkin.Relay.PendingCommands, command.request_id, self()) do
          {:ok, _} ->
            ref = Process.monitor(pid)
            send(pid, {:push_command, command})

            result =
              receive do
                {:command_response, %CommandResponse{} = response} ->
                  {:ok, response}

                {:DOWN, ^ref, :process, ^pid, _reason} ->
                  {:error, :not_connected}
              after
                timeout ->
                  {:error, :timeout}
              end

            Process.demonitor(ref, [:flush])
            Elixir.Registry.unregister(Loomkin.Relay.PendingCommands, command.request_id)
            result

          {:error, {:already_registered, _}} ->
            {:error, :duplicate_request_id}
        end

      :error ->
        {:error, :not_connected}
    end
  end

  # --- Push command from external callers ---

  @impl true
  def handle_info({:push_command, command}, socket) do
    push(socket, "command", Loomkin.Relay.Protocol.Command.to_map(command))
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Cleanup ---

  @impl true
  def terminate(_reason, socket) do
    Registry.unregister_daemon(self())

    Logger.info(
      "Daemon disconnected: user=#{socket.assigns.user_id} machine=#{socket.assigns[:machine_name]}"
    )

    :ok
  end

  # --- Role authorization ---

  @doc """
  Check whether a given `role` is authorized to perform `action`.

  Roles are hierarchical: observer < collaborator < owner.
  Returns `true` if the role has sufficient privileges, `false` otherwise.

  This function is public to support unit testing of the role-action matrix
  independently from a full channel integration test.
  """
  @spec authorized?(String.t(), String.t()) :: boolean()
  def authorized?(role, action) do
    case role do
      "owner" -> action in @owner_commands
      "collaborator" -> action in @collaborator_commands
      "observer" -> action in @observer_commands
      _ -> false
    end
  end

  # --- Helpers ---

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
