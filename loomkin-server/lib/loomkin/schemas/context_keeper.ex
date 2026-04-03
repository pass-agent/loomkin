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
    field :last_accessed_at, :utc_datetime
    field :access_count, :integer, default: 0
    field :last_agent_name, :string
    field :retrieval_mode_histogram, :map, default: %{}
    field :summary, :string
    field :relevance_score, :float, default: 0.0
    field :confidence, :float, default: 0.5
    field :success_count, :integer, default: 0
    field :miss_count, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(team_id topic source_agent token_count status)a
  @optional_fields ~w(messages metadata last_accessed_at access_count last_agent_name retrieval_mode_histogram summary relevance_score confidence success_count miss_count)a

  def changeset(keeper, attrs) do
    keeper
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
