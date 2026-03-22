defmodule Loomkin.Schemas.KindredProposal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kindred_proposals" do
    field :proposed_by, :string

    field :status, Ecto.Enum,
      values: [:pending, :approved, :rejected, :applied],
      default: :pending

    field :changes, :map, default: %{}
    field :review_notes, :string
    field :reviewed_at, :utc_datetime

    belongs_to :kindred, Loomkin.Schemas.Kindred
    belongs_to :reflection_snippet, Loomkin.Schemas.Snippet
    belongs_to :reviewed_by_user, Loomkin.Accounts.User, foreign_key: :reviewed_by, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(proposed_by)a
  @optional_fields ~w(status changes review_notes reviewed_at kindred_id reflection_snippet_id reviewed_by)a

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:proposed_by, min: 1, max: 200)
  end
end
