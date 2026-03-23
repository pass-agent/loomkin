defmodule LoomkinWeb.TeamChannel do
  @moduledoc """
  Channel for real-time team and agent status updates.

  Clients join `team:<team_id>` to receive live agent status
  changes, task updates, and discovery events.
  """

  use Phoenix.Channel

  alias Loomkin.Teams.Context, as: TeamContext

  @impl true
  def join("team:" <> team_id, _params, socket) do
    agents = TeamContext.list_agents(team_id)
    {:ok, %{agents: agents}, assign(socket, :team_id, team_id)}
  end

  @impl true
  def handle_in("get_agents", _params, socket) do
    agents = TeamContext.list_agents(socket.assigns.team_id)
    {:reply, {:ok, %{agents: agents}}, socket}
  end

  @impl true
  def handle_in("get_tasks", _params, socket) do
    tasks = TeamContext.list_cached_tasks(socket.assigns.team_id)
    {:reply, {:ok, %{tasks: tasks}}, socket}
  end

  @impl true
  def handle_in("send_to_agent", %{"agent_name" => agent_name, "message" => message}, socket) do
    team_id = socket.assigns.team_id
    Loomkin.Teams.Comms.send_to(team_id, agent_name, message)
    broadcast!(socket, "agent_message", %{to: agent_name, message: message, from: "user"})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("broadcast", %{"message" => message}, socket) do
    team_id = socket.assigns.team_id
    Loomkin.Teams.Comms.broadcast(team_id, message)
    broadcast!(socket, "team_broadcast", %{message: message, from: "user"})
    {:reply, :ok, socket}
  end
end
