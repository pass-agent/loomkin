defmodule LoomkinWeb.API.Auth do
  @moduledoc """
  Plug that authenticates API requests via Bearer token in the Authorization header.

  Assigns `current_scope` with the authenticated user for downstream controllers.
  Halts with 401 JSON on failure.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Loomkin.Accounts
  alias Loomkin.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Base.url_decode64(encoded, padding: false),
         {user, _token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => "unauthorized"})
        |> halt()
    end
  end
end
