defmodule Loomkin.Orchestration.Schema.WorkUnit do
  @moduledoc """
  A single unit of work inside an epic.

  Runs through the 4-phase pipeline of `Loomkin.Orchestration.WorkUnitPipeline`.
  `deps` lists the IDs of prior work units that must complete before this one
  becomes eligible; the orchestrator processes the dependency graph in
  topological order.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Loomkin.Orchestration.Schema.{DoDItem, Epic}

  @statuses ~w(pending implement validate adversarial_review commit done failed)a

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_work_units" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :file_scope, {:array, :string}, default: []
    field :deps, {:array, :binary_id}, default: []
    field :iteration, :integer, default: 0
    field :assigned_model, :string
    field :commit_sha, :string

    embeds_many :dod_items, DoDItem, on_replace: :delete
    belongs_to :epic, Epic, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id title epic_id)a
  @optional ~w(description status file_scope deps iteration assigned_model commit_sha)a

  def changeset(work_unit, attrs) do
    work_unit
    |> cast(attrs, @required ++ @optional)
    |> cast_embed(:dod_items)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:epic)
  end

  def statuses, do: @statuses
end
