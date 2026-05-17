defmodule Loomkin.Orchestration.Schema.CostEvent do
  @moduledoc """
  A single observed LLM call's token/cost accounting.

  Rows are append-only. Each row attributes the call to an originating epic
  (when known) and records the model + token counts. `cost_usd` is `nil` when
  the model is not in `Loomkin.Orchestration.CostTracker.PricingTable`, so
  future analysis can backfill once the table is updated.

  `epic_id` is intentionally not FK-constrained so accounting survives epic
  deletion.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_cost_events" do
    field :epic_id, :binary_id
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_usd, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id)a
  @optional ~w(epic_id model input_tokens output_tokens cost_usd)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
  end
end
