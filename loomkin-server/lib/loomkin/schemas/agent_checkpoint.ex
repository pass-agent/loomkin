defmodule Loomkin.Schemas.AgentCheckpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_checkpoints" do
    field :agent_name, :string
    field :team_id, :string
    field :iteration, :integer
    field :status, Ecto.Enum, values: [:paused, :hibernated, :crashed, :deployed]
    field :state_binary, :binary
    field :messages_snapshot, :map
    field :task_context, :map
    field :resume_guidance, :string

    belongs_to :session, Loomkin.Schemas.Session

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(agent_name team_id iteration status)a
  @optional_fields ~w(state_binary messages_snapshot task_context resume_guidance session_id)a

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:session_id)
  end
end
