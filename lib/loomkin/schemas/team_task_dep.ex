defmodule Loomkin.Schemas.TeamTaskDep do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_task_deps" do
    belongs_to :task, Loomkin.Schemas.TeamTask
    belongs_to :depends_on, Loomkin.Schemas.TeamTask
    field :dep_type, Ecto.Enum, values: [:blocks, :informs]
    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(task_id depends_on_id dep_type)a

  def changeset(dep, attrs) do
    dep
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:depends_on_id)
  end
end
