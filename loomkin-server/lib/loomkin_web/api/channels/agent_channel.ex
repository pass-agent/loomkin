defmodule LoomkinWeb.API.Channels.AgentChannel do
  @moduledoc """
  Phoenix.Channel "agents:{team_id}" for mobile/CLI clients.

  Delivers real-time agent events: status changes, streaming deltas,
  tool execution, and completions.
  """

  use Phoenix.Channel

  alias Loomkin.Relay.Protocol.Event

  @impl true
  def join("agents:" <> team_id, _params, socket) do
    user_id = socket.assigns.user_id

    case find_workspace_for_team(user_id, team_id) do
      {:ok, workspace_id} ->
        Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:#{workspace_id}")

        socket =
          socket
          |> assign(:team_id, team_id)
          |> assign(:workspace_id, workspace_id)

        {:ok, socket}

      :error ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:relay_event, %Event{} = event}, socket) do
    if event.team_id == socket.assigns.team_id and agent_event?(event.event_type) do
      case map_event(event.event_type) do
        nil -> :ok
        client_event -> push(socket, client_event, event.data)
      end
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Only forward agent-scoped events
  defp agent_event?("agent." <> _), do: true
  defp agent_event?(_), do: false

  # Map relay signal types to client-friendly event names
  defp map_event("agent.status_changed"), do: "agent_status"
  defp map_event("agent.stream.start"), do: "stream_start"
  defp map_event("agent.stream.delta"), do: "stream_delta"
  defp map_event("agent.stream.end"), do: "stream_end"
  defp map_event("agent.tool.executing"), do: "tool_executing"
  defp map_event("agent.tool.complete"), do: "tool_complete"
  defp map_event("agent.tool.error"), do: "tool_error"
  defp map_event(_), do: nil

  # Look up the workspace that owns this team by finding a session with this team_id
  defp find_workspace_for_team(user_id, team_id) do
    import Ecto.Query

    case Loomkin.Repo.one(
           from(s in Loomkin.Schemas.Session,
             where: s.user_id == ^user_id and s.team_id == ^team_id,
             select: s.workspace_id,
             limit: 1
           )
         ) do
      nil -> :error
      workspace_id -> {:ok, workspace_id}
    end
  end
end
