defmodule Loomkin.Orchestration.Schema.GateResult do
  @moduledoc """
  A single execution of a review gate.

  `verdicts` embeds the per-reviewer verdicts. `verdict` is the aggregate:
  `:pass` only if every reviewer passed, `:fail` otherwise.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Loomkin.Orchestration.Schema.{Epic, ReviewVerdict, WorkUnit}

  @verdicts ~w(pass fail)a
  @kinds ~w(plan_review design_review adversarial_review)a

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_gate_results" do
    field :kind, Ecto.Enum, values: @kinds
    field :verdict, Ecto.Enum, values: @verdicts
    field :iteration, :integer, default: 1
    field :payload_digest, :string

    embeds_many :verdicts, ReviewVerdict, on_replace: :delete
    belongs_to :epic, Epic, type: :binary_id
    belongs_to :work_unit, WorkUnit, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id kind verdict epic_id)a
  @optional ~w(iteration payload_digest work_unit_id)a

  def changeset(result, attrs) do
    result
    |> cast(attrs, @required ++ @optional)
    |> cast_embed(:verdicts)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:verdict, @verdicts)
    |> assoc_constraint(:epic)
  end

  def kinds, do: @kinds
  def verdicts, do: @verdicts
end
