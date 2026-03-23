defmodule LoomkinWeb.SessionChannel do
  @moduledoc """
  Channel for real-time session message streaming.

  Clients join `session:<session_id>` to receive live updates
  as agents produce messages, tool calls, and status changes.
  """

  use Phoenix.Channel

  alias Loomkin.Session.Persistence

  @impl true
  def join("session:" <> session_id, _params, socket) do
    case Persistence.get_session(session_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      _session ->
        {:ok, assign(socket, :session_id, session_id)}
    end
  end

  @impl true
  def handle_in("send_message", %{"content" => content}, socket) do
    attrs = %{
      session_id: socket.assigns.session_id,
      role: :user,
      content: content
    }

    case Persistence.save_message(attrs) do
      {:ok, message} ->
        broadcast!(socket, "new_message", serialize_message(message))
        {:reply, {:ok, serialize_message(message)}, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "failed to save message"}}, socket}
    end
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      role: to_string(message.role),
      content: message.content,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id,
      token_count: message.token_count,
      agent_name: message.agent_name,
      inserted_at: NaiveDateTime.to_iso8601(message.inserted_at)
    }
  end
end
