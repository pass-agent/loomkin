defmodule Loomkin.Schemas.PermissionAuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "permission_audit_logs" do
    belongs_to :session, Loomkin.Schemas.Session
    field :team_id, :string
    field :agent_name, :string
    field :tool_name, :string
    field :tool_path, :string
    field :action, Ecto.Enum, values: [:allow_once, :allow_always, :deny]
    field :comment, :string
    field :decided_at, :utc_datetime
  end

  @required_fields ~w(session_id team_id agent_name tool_name action decided_at)a
  @optional_fields ~w(tool_path comment)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:session_id)
  end
end
