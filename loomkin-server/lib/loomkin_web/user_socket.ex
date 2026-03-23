defmodule LoomkinWeb.UserSocket do
  use Phoenix.Socket

  alias Loomkin.Accounts
  alias Loomkin.Accounts.Scope

  channel "session:*", LoomkinWeb.SessionChannel
  channel "team:*", LoomkinWeb.TeamChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Accounts.get_user_by_session_token(token) do
      {user, _token_inserted_at} ->
        {:ok, assign(socket, :current_scope, Scope.for_user(user))}

      nil ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_scope.user.id}"
end
