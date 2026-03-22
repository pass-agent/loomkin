defmodule LoomkinWeb.UserRegistrationController do
  use LoomkinWeb, :controller

  import Phoenix.Component, only: [to_form: 1]

  alias Loomkin.Accounts
  alias Loomkin.Accounts.User

  def new(conn, _params) do
    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, form: to_form(changeset))
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        conn
        |> put_flash(
          :info,
          "An email was sent to #{user.email}, please access it to confirm your account."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, form: to_form(changeset))
    end
  end
end
