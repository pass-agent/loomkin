defmodule Loomkin.Orchestration.Schema.PhaseMetric do
  @moduledoc """
  A single observed event from the orchestration pipeline.

  Rows are append-only. Each row captures one event — a phase transition, a
  gate verdict, an escalation, or the completion/failure of a work unit. The
  dashboard (and `Loomkin.Orchestration.Metrics.aggregate/1`) derives
  pass-rates, iteration distributions, and per-model performance from these
  rows.

  `epic_id` and `work_unit_id` are intentionally not FK-constrained so that
  metrics survive deletion of upstream rows (we keep observability data even
  when an epic is purged).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @event_kinds ~w(phase_entered gate_verdict escalated work_unit_completed work_unit_failed)a
  @verdicts ~w(pass fail unknown)a

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_phase_metrics" do
    field :epic_id, :binary_id
    field :work_unit_id, :binary_id
    field :event_kind, Ecto.Enum, values: @event_kinds
    field :phase, :string
    field :gate, :string
    field :verdict, Ecto.Enum, values: @verdicts
    field :iteration, :integer, default: 1
    field :duration_ms, :integer
    field :model, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id event_kind)a
  @optional ~w(epic_id work_unit_id phase gate verdict iteration duration_ms model metadata)a

  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_kind, @event_kinds)
    |> validate_inclusion(:verdict, @verdicts ++ [nil])
    |> validate_number(:iteration, greater_than_or_equal_to: 1)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end

  def event_kinds, do: @event_kinds
  def verdicts, do: @verdicts
end
