defmodule LoomkinWeb.API.Channels.SessionChannel do
  @moduledoc """
  Phoenix.Channel "session:{session_id}" for mobile/CLI clients.

  Delivers real-time session events: messages, status changes, errors,
  and cancellations. Events originate from the relay PubSub bridge
  (daemon → cloud → this channel → mobile client).
  """

  use Phoenix.Channel

  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Session.Persistence

  @impl true
  def join("session:" <> session_id, _params, socket) do
    user_id = socket.assigns.user_id

    case Persistence.get_session(session_id) do
      %{user_id: ^user_id, workspace_id: workspace_id} = session ->
        if workspace_id do
          Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:#{workspace_id}")
        end

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:workspace_id, workspace_id)
          |> assign(:team_id, session.team_id)

        {:ok, socket}

      %{user_id: _other} ->
        {:error, %{reason: "unauthorized"}}

      nil ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info({:relay_event, %Event{} = event}, socket) do
    if event.session_id == socket.assigns.session_id do
      case map_event(event.event_type) do
        nil -> :ok
        client_event -> push(socket, client_event, event.data)
      end
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Map relay signal types to client-friendly event names
  defp map_event("session.new_message"), do: "message_received"
  defp map_event("session.status_changed"), do: "status_changed"
  defp map_event("session.context_updated"), do: "context_updated"
  defp map_event("session.llm_error"), do: "llm_error"
  defp map_event("session.cancelled"), do: "cancelled"
  defp map_event("agent.stream.delta"), do: "stream_delta"
  defp map_event("agent.stream.start"), do: "stream_start"
  defp map_event("agent.stream.end"), do: "stream_end"
  defp map_event(_), do: nil
end
