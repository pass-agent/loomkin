defmodule LoomkinWeb.Api.AuthController do
  use LoomkinWeb, :controller

  alias Loomkin.Accounts

  action_fallback LoomkinWeb.Api.FallbackController

  @doc """
  POST /api/v1/auth/register
  Creates a new user account and returns a bearer token.
  """
  def register(conn, %{"email" => email} = params) do
    case Accounts.register_user(%{email: email, password: params["password"]}) do
      {:ok, user} ->
        token = Accounts.generate_user_session_token(user)

        conn
        |> put_status(:created)
        |> json(%{
          token: Base.url_encode64(token),
          user: serialize_user(user)
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/v1/auth/login
  If `password` is provided and valid, returns a bearer token directly.
  Otherwise sends a magic link login email and returns 200 regardless of whether the email exists.
  """
  def login(conn, %{"email" => email, "password" => password})
      when is_binary(password) and password != "" do
    case Accounts.get_user_by_email_and_password(email, password) do
      %{} = user ->
        token = Accounts.generate_user_session_token(user)

        json(conn, %{
          token: Base.url_encode64(token),
          user: serialize_user(user)
        })

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end

  def login(conn, %{"email" => email}) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(user, fn token ->
        "loomkin://auth/confirm?token=#{token}"
      end)
    end

    json(conn, %{message: "if the email is registered, you will receive a login link"})
  end

  @doc """
  POST /api/v1/auth/login/confirm
  Confirms a magic link token and returns a bearer token.
  """
  def confirm(conn, %{"token" => token}) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        session_token = Accounts.generate_user_session_token(user)

        json(conn, %{
          token: Base.url_encode64(session_token),
          user: serialize_user(user)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token", message: "token is invalid or expired"})
    end
  end

  @doc """
  POST /api/v1/auth/logout
  Deletes the current session token.
  """
  def logout(conn, _params) do
    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Base.url_decode64(encoded_token) do
      Accounts.delete_user_session_token(token)
    end

    json(conn, %{message: "logged out"})
  end

  @doc """
  GET /api/v1/auth/me
  Returns the current user's profile.
  """
  def me(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{user: serialize_user(user)})
  end

  defp serialize_user(user) do
    %{
      id: user.id,
      email: user.email,
      username: user.username,
      confirmed_at: user.confirmed_at,
      inserted_at: user.inserted_at
    }
  end
end
