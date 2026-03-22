defmodule Loomkin.Schemas.AuthToken do
  @moduledoc """
  Ecto schema for persisted OAuth tokens.

  Tokens are encrypted at rest using Plug.Crypto. Each provider has at most
  one active token row (enforced via unique index on `:provider`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "auth_tokens" do
    field :provider, :string
    field :access_token_encrypted, :binary
    field :refresh_token_encrypted, :binary
    field :expires_at, :utc_datetime
    field :account_id, :string
    field :scopes, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Loomkin.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(provider access_token_encrypted)a
  @optional_fields ~w(refresh_token_encrypted expires_at account_id scopes metadata user_id)a

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:provider)
  end
end
