defmodule Loomkin.Schemas.WorkspaceMembership do
  @moduledoc """
  Tracks which users have access to which workspaces and their role.

  Roles:
    * `:owner` — full control, manage members, delete workspace
    * `:collaborator` — can run agents on their own worktree, send commands
    * `:observer` — read-only view of agent activity
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: [:owner, :collaborator, :observer], default: :collaborator
    field :worktree_path, :string
    field :accepted_at, :utc_datetime

    belongs_to :workspace, Loomkin.Workspace
    belongs_to :user, Loomkin.Accounts.User, type: :id
    belongs_to :invited_by, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(role)a
  @optional_fields ~w(invited_by_id worktree_path accepted_at)a

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:workspace_id, :user_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end
end
