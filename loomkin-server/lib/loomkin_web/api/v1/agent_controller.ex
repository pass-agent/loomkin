defmodule LoomkinWeb.API.V1.AgentController do
  use LoomkinWeb, :controller

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Relay.Server.Registry

  def index(conn, %{"id" => team_id}) do
    user = conn.assigns.current_scope.user

    # Find the workspace that owns this team by scanning the registry
    case find_workspace_for_team(user.id, team_id) do
      {:ok, workspace_id} ->
        command = %Command{
          request_id: Ecto.UUID.generate(),
          action: "get_agents",
          workspace_id: workspace_id,
          payload: %{"team_id" => team_id}
        }

        case DaemonChannel.send_command(user.id, workspace_id, command) do
          {:ok, response} ->
            json(conn, %{"ok" => true, "data" => response.data})

          {:error, :timeout} ->
            conn
            |> put_status(504)
            |> json(%{"ok" => false, "error" => "daemon timeout"})

          {:error, :not_connected} ->
            conn
            |> put_status(503)
            |> json(%{"ok" => false, "error" => "daemon not connected"})
        end

      :error ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "team not found on any connected workspace"})
    end
  end

  defp find_workspace_for_team(user_id, team_id) do
    Registry.list_workspaces(user_id)
    |> Enum.find_value(:error, fn {workspace_id, info} ->
      if info.team_id == team_id, do: {:ok, workspace_id}
    end)
  end
end
