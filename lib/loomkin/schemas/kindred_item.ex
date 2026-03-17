defmodule Loomkin.Schemas.KindredItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kindred_items" do
    field :item_type, Ecto.Enum, values: [:kin_config, :skill_ref, :prompt_template]
    field :position, :integer, default: 0
    field :content, :map, default: %{}

    belongs_to :kindred, Loomkin.Schemas.Kindred
    belongs_to :source_snippet, Loomkin.Schemas.Snippet

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(item_type)a
  @optional_fields ~w(position content kindred_id source_snippet_id)a

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
