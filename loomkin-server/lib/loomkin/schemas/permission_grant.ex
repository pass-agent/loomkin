defmodule Loomkin.Schemas.PermissionGrant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "permission_grants" do
    belongs_to :session, Loomkin.Schemas.Session
    belongs_to :user, Loomkin.Accounts.User
    field :tool, :string
    field :scope, :string, default: "*"
    field :granted_at, :utc_datetime
  end

  @required_fields ~w(session_id tool)a
  @optional_fields ~w(scope granted_at user_id)a

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:session_id)
  end
end
