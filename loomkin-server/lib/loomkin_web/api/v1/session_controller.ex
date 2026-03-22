defmodule LoomkinWeb.API.V1.SessionController do
  use LoomkinWeb, :controller

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Session.Persistence

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    user = conn.assigns.current_scope.user

    command = %Command{
      request_id: Ecto.UUID.generate(),
      action: "create_session",
      workspace_id: workspace_id,
      payload: Map.take(params, ["model", "project_path", "title"])
    }

    case DaemonChannel.send_command(user.id, workspace_id, command) do
      {:ok, response} ->
        conn
        |> put_status(201)
        |> json(%{"ok" => true, "data" => response.data})

      {:error, :not_connected} ->
        conn
        |> put_status(503)
        |> json(%{"ok" => false, "error" => "daemon not connected"})

      {:error, :timeout} ->
        conn
        |> put_status(504)
        |> json(%{"ok" => false, "error" => "daemon timeout"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"ok" => false, "error" => "workspace_id required"})
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    case Persistence.get_session(id) do
      %{user_id: uid} = session when uid == user.id ->
        json(conn, %{"ok" => true, "data" => %{"session" => session_json(session)}})

      %{user_id: nil} = session ->
        json(conn, %{"ok" => true, "data" => %{"session" => session_json(session)}})

      _ ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "session not found"})
    end
  end

  def messages(conn, %{"id" => session_id} = params) do
    user = conn.assigns.current_scope.user

    case Persistence.get_session(session_id) do
      %{user_id: uid} = _session when uid == user.id or is_nil(uid) ->
        all_messages = Persistence.load_messages(session_id)

        offset = parse_int(params["offset"], 0)
        limit = parse_int(params["limit"], 50)

        paginated =
          all_messages
          |> Enum.drop(offset)
          |> Enum.take(limit)

        json(conn, %{
          "ok" => true,
          "data" => %{
            "messages" => Enum.map(paginated, &message_json/1),
            "total" => length(all_messages),
            "offset" => offset,
            "limit" => limit
          }
        })

      _ ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "session not found"})
    end
  end

  def send_message(conn, %{"id" => session_id, "text" => text}) do
    user = conn.assigns.current_scope.user

    case Persistence.get_session(session_id) do
      %{user_id: uid, workspace_id: workspace_id}
      when uid == user.id and not is_nil(workspace_id) ->
        command = %Command{
          request_id: Ecto.UUID.generate(),
          action: "send_message",
          workspace_id: workspace_id,
          session_id: session_id,
          payload: %{"text" => text}
        }

        DaemonChannel.send_command(user.id, workspace_id, command)

        conn
        |> put_status(202)
        |> json(%{"ok" => true, "data" => %{"request_id" => command.request_id}})

      %{user_id: uid} when uid != user.id ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "session not found"})

      _ ->
        conn
        |> put_status(503)
        |> json(%{"ok" => false, "error" => "session has no workspace or daemon not connected"})
    end
  end

  def send_message(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"ok" => false, "error" => "text required"})
  end

  def cancel(conn, %{"id" => session_id}) do
    user = conn.assigns.current_scope.user

    case Persistence.get_session(session_id) do
      %{user_id: uid, workspace_id: workspace_id}
      when uid == user.id and not is_nil(workspace_id) ->
        command = %Command{
          request_id: Ecto.UUID.generate(),
          action: "cancel",
          workspace_id: workspace_id,
          session_id: session_id,
          payload: %{}
        }

        DaemonChannel.send_command(user.id, workspace_id, command)

        conn
        |> put_status(202)
        |> json(%{"ok" => true, "data" => %{"request_id" => command.request_id}})

      _ ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false, "error" => "session not found or not connected"})
    end
  end

  # --- Helpers ---

  defp session_json(session) do
    %{
      "id" => session.id,
      "title" => session.title,
      "status" => to_string(session.status),
      "model" => session.model,
      "project_path" => session.project_path,
      "team_id" => session.team_id,
      "prompt_tokens" => session.prompt_tokens,
      "completion_tokens" => session.completion_tokens,
      "cost_usd" => session.cost_usd && Decimal.to_string(session.cost_usd),
      "workspace_id" => session.workspace_id,
      "inserted_at" => DateTime.to_iso8601(session.inserted_at),
      "updated_at" => DateTime.to_iso8601(session.updated_at)
    }
  end

  defp message_json(msg) do
    %{
      "id" => msg.id,
      "role" => to_string(msg.role),
      "content" => msg.content,
      "tool_calls" => msg.tool_calls,
      "tool_call_id" => msg.tool_call_id,
      "token_count" => msg.token_count,
      "inserted_at" => DateTime.to_iso8601(msg.inserted_at)
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default
end
