defmodule LoomkinWeb.Api.ShareController do
  use LoomkinWeb, :controller

  alias Loomkin.SessionShares

  def create(conn, %{"session_id" => session_id} = params) do
    user_id = conn.assigns.current_scope.user.id

    opts = [
      label: params["label"],
      permission: parse_permission(params["permission"])
    ]

    case SessionShares.create_share(session_id, user_id, opts) do
      {:ok, share} ->
        url = share_url(conn, share.token)

        conn
        |> put_status(:created)
        |> json(%{
          share: serialize(share),
          url: url,
          token: share.token
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def index(conn, %{"session_id" => session_id}) do
    shares = SessionShares.list_shares(session_id)
    json(conn, %{shares: Enum.map(shares, &serialize/1)})
  end

  def delete(conn, %{"id" => share_id}) do
    case SessionShares.revoke_share(share_id) do
      {:ok, _share} -> json(conn, %{message: "Share revoked"})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp serialize(share) do
    %{
      id: share.id,
      session_id: share.session_id,
      label: share.label,
      permission: share.permission,
      expires_at: share.expires_at && DateTime.to_iso8601(share.expires_at),
      inserted_at: share.inserted_at && DateTime.to_iso8601(share.inserted_at)
    }
  end

  defp share_url(conn, token) do
    "#{LoomkinWeb.Endpoint.url()}/s/#{token}"
  end

  defp parse_permission("collaborate"), do: :collaborate
  defp parse_permission(_), do: :view

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
