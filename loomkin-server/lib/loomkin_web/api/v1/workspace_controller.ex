defmodule LoomkinWeb.API.V1.WorkspaceController do
  use LoomkinWeb, :controller

  alias Loomkin.Relay.Server.Registry
  alias Loomkin.Repo
  alias Loomkin.Workspace

  import Ecto.Query

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    user_id = user.id

    # Online workspaces from relay registry
    online =
      Registry.list_workspaces(user_id)
      |> Enum.map(fn {workspace_id, info} ->
        %{
          "id" => workspace_id,
          "name" => info.workspace_name,
          "project_path" => info.project_path,
          "machine_name" => info.machine_name,
          "status" => info.status,
          "team_id" => info.team_id,
          "agent_count" => info.agent_count,
          "online" => true,
          "last_heartbeat" => DateTime.to_iso8601(info.last_heartbeat)
        }
      end)

    online_ids = Enum.map(online, & &1["id"])

    # Offline workspaces from DB (not currently connected via relay)
    offline =
      Workspace
      |> where([w], w.user_id == ^user_id and w.status != :archived)
      |> where([w], w.id not in ^online_ids)
      |> order_by([w], desc: w.updated_at)
      |> Repo.all()
      |> Enum.map(fn ws ->
        %{
          "id" => ws.id,
          "name" => ws.name,
          "project_paths" => ws.project_paths,
          "status" => to_string(ws.status),
          "team_id" => ws.team_id,
          "online" => false
        }
      end)

    json(conn, %{"ok" => true, "data" => %{"workspaces" => online ++ offline}})
  end

  def show(conn, %{"id" => workspace_id}) do
    user = conn.assigns.current_scope.user
    user_id = user.id

    case Registry.lookup_workspace(user_id, workspace_id) do
      {:ok, info} ->
        json(conn, %{
          "ok" => true,
          "data" => %{
            "workspace" => %{
              "id" => workspace_id,
              "name" => info.workspace_name,
              "project_path" => info.project_path,
              "machine_name" => info.machine_name,
              "status" => info.status,
              "team_id" => info.team_id,
              "agent_count" => info.agent_count,
              "online" => true,
              "last_heartbeat" => DateTime.to_iso8601(info.last_heartbeat)
            }
          }
        })

      :error ->
        case Repo.get(Workspace, workspace_id) do
          %Workspace{user_id: ^user_id} = ws ->
            json(conn, %{
              "ok" => true,
              "data" => %{
                "workspace" => %{
                  "id" => ws.id,
                  "name" => ws.name,
                  "project_paths" => ws.project_paths,
                  "status" => to_string(ws.status),
                  "team_id" => ws.team_id,
                  "online" => false
                }
              }
            })

          _ ->
            conn
            |> put_status(404)
            |> json(%{"ok" => false, "error" => "workspace not found"})
        end
    end
  end
end
