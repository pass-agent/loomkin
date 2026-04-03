defmodule LoomkinWeb.UserRegistrationController do
  use LoomkinWeb, :controller

  import Phoenix.Component, only: [to_form: 1]

  alias Loomkin.Accounts
  alias Loomkin.Accounts.User

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})
    render(conn, :new, form: to_form(changeset))
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Account created successfully.")
        |> LoomkinWeb.UserAuth.log_in_user(user, user_params)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, form: to_form(changeset))
    end
  end
end
