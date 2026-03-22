defmodule Loomkin.Relay.Server.Socket do
  @moduledoc """
  Phoenix.Socket for daemon WebSocket connections.

  Authenticates via bearer token passed as a `token` param on connect.
  Assigns the authenticated user_id to the socket for use by channels.
  """

  use Phoenix.Socket

  alias Loomkin.Accounts

  channel "daemon:lobby", Loomkin.Relay.Server.DaemonChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Accounts.get_user_by_session_token(token) do
      {user, _token_inserted_at} ->
        {:ok, assign(socket, :user_id, user.id)}

      nil ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.user_id}"
end
