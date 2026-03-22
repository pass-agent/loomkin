defmodule Loomkin.Schemas.OrganizationMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member], default: :member

    belongs_to :organization, Loomkin.Schemas.Organization
    belongs_to :user, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(role)a
  @optional_fields ~w(organization_id user_id)a

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, [:owner, :admin, :member])
    |> unique_constraint([:organization_id, :user_id])
  end
end
