defmodule Loomkin.Schemas.TaskAssumption do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_assumptions" do
    belongs_to :task, Loomkin.Schemas.TeamTask
    field :assumption_key, :string
    field :assumed_value, :string
    field :actual_value, :string
    field :matched, :boolean

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(task_id assumption_key)a
  @optional_fields ~w(assumed_value actual_value matched)a

  def changeset(assumption, attrs) do
    assumption
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:assumption_key, min: 1)
    |> foreign_key_constraint(:task_id)
  end
end
