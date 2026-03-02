defmodule Loomkin.Schemas.TeamTask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_tasks" do
    field :team_id, :string
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:pending, :assigned, :in_progress, :completed, :failed]
    field :owner, :string
    field :priority, :integer, default: 3
    field :model_hint, :string
    field :result, :string
    field :cost_usd, :decimal, default: 0
    field :tokens_used, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(team_id title status)a
  @optional_fields ~w(description owner priority model_hint result cost_usd tokens_used)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
