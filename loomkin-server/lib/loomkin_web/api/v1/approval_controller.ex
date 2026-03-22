defmodule LoomkinWeb.API.V1.ApprovalController do
  use LoomkinWeb, :controller

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Session.Persistence

  def approve(conn, %{"session_id" => session_id, "tool_name" => tool_name} = params)
      when is_binary(tool_name) and tool_name != "" do
    relay_approval(conn, session_id, "approve_tool", %{
      "tool_name" => tool_name,
      "tool_path" => params["tool_path"] || ""
    })
  end

  def approve(conn, _params) do
    conn |> put_status(400) |> json(%{"ok" => false, "error" => "tool_name required"})
  end

  def deny(conn, %{"session_id" => session_id, "tool_name" => tool_name} = params)
      when is_binary(tool_name) and tool_name != "" do
    relay_approval(conn, session_id, "deny_tool", %{
      "tool_name" => tool_name,
      "reason" => params["reason"] || "denied"
    })
  end

  def deny(conn, _params) do
    conn |> put_status(400) |> json(%{"ok" => false, "error" => "tool_name required"})
  end

  defp relay_approval(conn, session_id, action, payload) do
    user = conn.assigns.current_scope.user

    case Persistence.get_session(session_id) do
      %{user_id: uid, workspace_id: workspace_id}
      when uid == user.id and not is_nil(workspace_id) ->
        command = %Command{
          request_id: Ecto.UUID.generate(),
          action: action,
          workspace_id: workspace_id,
          session_id: session_id,
          payload: payload
        }

        case DaemonChannel.send_command(user.id, workspace_id, command) do
          {:ok, response} ->
            json(conn, %{"ok" => true, "data" => response.data})

          {:error, :not_connected} ->
            conn
            |> put_status(503)
            |> json(%{"ok" => false, "error" => "daemon not connected"})

          {:error, :timeout} ->
            conn
            |> put_status(504)
            |> json(%{"ok" => false, "error" => "daemon timeout"})
        end

      _ ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "session not found or not connected"})
    end
  end
end
