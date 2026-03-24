defmodule LoomkinWeb.UserSocket do
  use Phoenix.Socket

  alias Loomkin.Accounts
  alias Loomkin.Accounts.Scope

  channel "session:*", LoomkinWeb.SessionChannel
  channel "team:*", LoomkinWeb.TeamChannel

  @impl true
  def connect(%{"token" => encoded_token}, socket, _connect_info) do
    with {:ok, token} <- Base.url_decode64(encoded_token),
         {user, _token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      {:ok, assign(socket, :current_scope, Scope.for_user(user))}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_scope.user.id}"
end
