defmodule Loomkin.Schemas.SessionShare do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @token_bytes 32

  schema "session_shares" do
    field :token_hash, :binary
    field :token, :string, virtual: true, redact: true
    field :label, :string
    field :permission, Ecto.Enum, values: [:view, :collaborate], default: :view
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :session, Loomkin.Schemas.Session
    belongs_to :user, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(session_id user_id)a
  @optional_fields ~w(label permission expires_at revoked_at)a

  def changeset(share, attrs) do
    share
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> put_token()
  end

  def revoke_changeset(share) do
    change(share, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp put_token(changeset) do
    if changeset.valid? and is_nil(get_field(changeset, :token_hash)) do
      token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
      hash = :crypto.hash(:sha256, token)

      changeset
      |> put_change(:token, token)
      |> put_change(:token_hash, hash)
    else
      changeset
    end
  end

  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
  end
end
