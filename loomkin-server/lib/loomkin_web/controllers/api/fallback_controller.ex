defmodule LoomkinWeb.Api.FallbackController do
  use LoomkinWeb, :controller

  def options(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    message =
      errors
      |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
      |> Enum.join("; ")

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation_failed", message: message, errors: errors})
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end
end
