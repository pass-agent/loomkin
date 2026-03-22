defmodule LoomkinWeb.API.V1.AuthController do
  use LoomkinWeb, :controller

  alias Loomkin.Accounts

  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        token = Accounts.generate_user_session_token(user)
        encoded = Base.url_encode64(token)

        json(conn, %{
          "ok" => true,
          "data" => %{
            "token" => encoded,
            "user" => user_json(user)
          }
        })

      nil ->
        conn
        |> put_status(401)
        |> json(%{"ok" => false, "error" => "invalid_credentials"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"ok" => false, "error" => "email and password required"})
  end

  def me(conn, _params) do
    user = conn.assigns.current_scope.user

    json(conn, %{
      "ok" => true,
      "data" => %{"user" => user_json(user)}
    })
  end

  defp user_json(user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "username" => user.username,
      "display_name" => user.display_name,
      "avatar_url" => user.avatar_url
    }
  end
end
