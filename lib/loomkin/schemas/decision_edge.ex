defmodule Loomkin.Schemas.DecisionEdge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "decision_edges" do
    field :change_id, Ecto.UUID, autogenerate: true
    belongs_to :from_node, Loomkin.Schemas.DecisionNode
    belongs_to :to_node, Loomkin.Schemas.DecisionNode

    field :edge_type, Ecto.Enum,
      values: [:leads_to, :chosen, :rejected, :requires, :blocks, :enables, :supersedes]

    field :weight, :float, default: 1.0
    field :rationale, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(from_node_id to_node_id edge_type)a
  @optional_fields ~w(weight rationale change_id)a

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:from_node_id)
    |> foreign_key_constraint(:to_node_id)
  end
end
