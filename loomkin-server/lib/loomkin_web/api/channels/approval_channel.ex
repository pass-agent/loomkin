defmodule LoomkinWeb.API.Channels.ApprovalChannel do
  @moduledoc """
  Phoenix.Channel "approvals:{session_id}" for mobile/CLI clients.

  Delivers tool permission request and resolution events so mobile users
  can approve or deny tool executions in real time.
  """

  use Phoenix.Channel

  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Session.Persistence

  @impl true
  def join("approvals:" <> session_id, _params, socket) do
    user_id = socket.assigns.user_id

    case Persistence.get_session(session_id) do
      %{user_id: ^user_id, workspace_id: workspace_id} ->
        if workspace_id do
          Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:#{workspace_id}")
        end

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:workspace_id, workspace_id)

        {:ok, socket}

      %{user_id: _other} ->
        {:error, %{reason: "unauthorized"}}

      nil ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info({:relay_event, %Event{} = event}, socket) do
    if event.session_id == socket.assigns.session_id and approval_event?(event.event_type) do
      case map_event(event.event_type) do
        nil -> :ok
        client_event -> push(socket, client_event, event.data)
      end
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Only forward approval-related events
  defp approval_event?("team.permission." <> _), do: true
  defp approval_event?("approval." <> _), do: true
  defp approval_event?(_), do: false

  # Map relay signal types to client-friendly event names
  defp map_event("team.permission.request"), do: "permission_requested"
  defp map_event("team.permission.resolved"), do: "approval_resolved"
  defp map_event("approval.requested"), do: "permission_requested"
  defp map_event("approval.resolved"), do: "approval_resolved"
  defp map_event(_), do: nil
end
