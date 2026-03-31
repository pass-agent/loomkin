defmodule Loomkin.Relay.Server.Socket do
  @moduledoc """
  Phoenix.Socket for daemon WebSocket connections.

  Authenticates via macaroon daemon token passed as a `token` param on connect.
  Verifies the token signature and caveats, then assigns `user_id`,
  `workspace_id`, and `role` to the socket for use by channels.
  """

  use Phoenix.Socket

  alias Loomkin.Accounts

  channel "daemon:*", Loomkin.Relay.Server.DaemonChannel

  @valid_roles ~w(owner collaborator observer)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info)
      when is_binary(token) and byte_size(token) > 0 do
    with {:ok, claims} <- Accounts.verify_daemon_token(token),
         {:ok, role} <- validate_role(claims["role"]),
         {:ok, user_id} <- parse_user_id(claims["user_id"]) do
      socket =
        socket
        |> assign(:user_id, user_id)
        |> assign(:workspace_id, claims["workspace_id"])
        |> assign(:role, role)

      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.user_id}"

  defp validate_role(role) when role in @valid_roles, do: {:ok, role}
  defp validate_role(_role), do: :error

  defp parse_user_id(id) when is_integer(id), do: {:ok, id}

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_user_id(_id), do: :error
end
