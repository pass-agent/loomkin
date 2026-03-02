defmodule Loomkin.Schemas.ContextKeeper do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "context_keepers" do
    field :team_id, :string
    field :topic, :string
    field :source_agent, :string
    field :messages, :map
    field :token_count, :integer
    field :metadata, :map
    field :status, Ecto.Enum, values: [:active, :archived]
    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(team_id topic source_agent token_count status)a
  @optional_fields ~w(messages metadata)a

  def changeset(keeper, attrs) do
    keeper
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
