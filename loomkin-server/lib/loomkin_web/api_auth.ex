defmodule LoomkinWeb.ApiAuth do
  @moduledoc """
  Plugs for API bearer token authentication.

  Extracts `Authorization: Bearer <token>` from the request,
  looks up the user via the existing session token infrastructure,
  and builds a `Scope` for context module calls.
  """

  import Plug.Conn

  alias Loomkin.Accounts
  alias Loomkin.Accounts.Scope

  @doc """
  Plug that fetches the current user from an API bearer token.

  Assigns `current_scope` to the connection. If no valid token is found,
  `current_scope` is nil.
  """
  def fetch_api_user(conn, _opts) do
    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Base.url_decode64(encoded_token),
         {user, _token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ -> assign(conn, :current_scope, nil)
    end
  end

  @doc """
  Plug that requires a valid API bearer token.

  Halts with 401 if no authenticated user is found.
  Must be called after `fetch_api_user/2`.
  """
  def require_api_auth(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.json(%{error: "unauthorized", message: "valid bearer token required"})
      |> halt()
    end
  end
end
