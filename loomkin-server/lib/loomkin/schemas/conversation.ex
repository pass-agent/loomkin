defmodule Loomkin.Schemas.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "conversations" do
    field :team_id, :string
    field :topic, :string
    field :context, :string
    field :spawned_by, :string
    field :turn_strategy, :string
    field :status, :string, default: "active"
    field :end_reason, :string
    field :current_round, :integer, default: 1
    field :max_rounds, :integer, default: 10
    field :tokens_used, :integer, default: 0
    field :max_tokens, :integer
    field :participants, {:array, :map}, default: []
    field :history, {:array, :map}, default: []
    field :summary, :map
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(id team_id topic status)a
  @optional_fields ~w(context spawned_by turn_strategy end_reason current_round max_rounds tokens_used max_tokens participants history summary started_at ended_at)a

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
