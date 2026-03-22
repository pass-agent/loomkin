defmodule LoomkinWeb.API.ClientSocket do
  @moduledoc """
  Phoenix.Socket for mobile and CLI client WebSocket connections.

  Authenticates via bearer token passed as a `token` param on connect.
  Assigns the authenticated user_id to the socket for use by channels.
  """

  use Phoenix.Socket

  alias Loomkin.Accounts

  channel "session:*", LoomkinWeb.API.Channels.SessionChannel
  channel "agents:*", LoomkinWeb.API.Channels.AgentChannel
  channel "approvals:*", LoomkinWeb.API.Channels.ApprovalChannel

  @impl true
  def connect(%{"token" => encoded}, socket, _connect_info) when is_binary(encoded) do
    with {:ok, token} <- Base.url_decode64(encoded, padding: false),
         {user, _token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      {:ok, assign(socket, :user_id, user.id)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "client_socket:#{socket.assigns.user_id}"
end
