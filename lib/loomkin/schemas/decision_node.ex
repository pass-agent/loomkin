defmodule Loomkin.Schemas.DecisionNode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "decision_nodes" do
    field :change_id, Ecto.UUID, autogenerate: true

    field :node_type, Ecto.Enum,
      values: [:goal, :decision, :option, :action, :outcome, :observation, :revisit]

    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:active, :superseded, :abandoned], default: :active
    field :confidence, :integer
    field :metadata, :map, default: %{}
    field :agent_name, :string

    belongs_to :session, Loomkin.Schemas.Session

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(node_type title)a
  @optional_fields ~w(description status confidence metadata session_id change_id agent_name)a

  def changeset(node, attrs) do
    node
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:confidence, 0..100)
  end
end
