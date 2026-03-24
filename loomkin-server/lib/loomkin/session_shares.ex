defmodule Loomkin.SessionShares do
  @moduledoc "Context for managing session share links."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.SessionShare

  @default_expiry_hours 24 * 7

  def create_share(session_id, user_id, opts \\ []) do
    attrs = %{
      session_id: session_id,
      user_id: user_id,
      label: opts[:label],
      permission: opts[:permission] || :view,
      expires_at: opts[:expires_at] || default_expiry()
    }

    %SessionShare{}
    |> SessionShare.changeset(attrs)
    |> Repo.insert()
  end

  def get_by_token(token) when is_binary(token) do
    hash = SessionShare.hash_token(token)

    SessionShare
    |> where([s], s.token_hash == ^hash)
    |> where([s], is_nil(s.revoked_at))
    |> where([s], s.expires_at > ^DateTime.utc_now())
    |> Repo.one()
  end

  def list_shares(session_id) do
    SessionShare
    |> where([s], s.session_id == ^session_id)
    |> where([s], is_nil(s.revoked_at))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def revoke_share(share_id) do
    case Repo.get(SessionShare, share_id) do
      nil -> {:error, :not_found}
      share -> share |> SessionShare.revoke_changeset() |> Repo.update()
    end
  end

  def revoke_all(session_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    SessionShare
    |> where([s], s.session_id == ^session_id)
    |> where([s], is_nil(s.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])
  end

  defp default_expiry do
    DateTime.utc_now()
    |> DateTime.add(@default_expiry_hours * 3600, :second)
    |> DateTime.truncate(:second)
  end
end
