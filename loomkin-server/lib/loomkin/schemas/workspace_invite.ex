defmodule Loomkin.Schemas.WorkspaceInvite do
  @moduledoc """
  Pending invitations to join a workspace.

  Invites have a lifecycle: pending -> accepted/declined/expired/revoked.
  Each invite carries a unique cryptographic token for acceptance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @invite_ttl_days 7

  schema "workspace_invites" do
    field :email, :string
    field :role, Ecto.Enum, values: [:collaborator, :observer], default: :collaborator
    field :token, :string

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :declined, :expired, :revoked],
      default: :pending

    field :expires_at, :utc_datetime

    belongs_to :workspace, Loomkin.Workspace
    belongs_to :invited_by, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(email role)a
  @optional_fields ~w(status expires_at token)a

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be a valid email")
    |> maybe_generate_token()
    |> maybe_set_expiry()
    |> unique_constraint(:token)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_id)
  end

  defp maybe_generate_token(changeset) do
    if get_field(changeset, :token) do
      changeset
    else
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      put_change(changeset, :token, token)
    end
  end

  defp maybe_set_expiry(changeset) do
    if get_field(changeset, :expires_at) do
      changeset
    else
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@invite_ttl_days * 24 * 3600, :second)
        |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    end
  end
end
