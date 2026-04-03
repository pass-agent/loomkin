defmodule Loomkin.Schemas.AgentMetric do
  @moduledoc "Persisted per-task performance metrics for cross-session learning."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_metrics" do
    field :team_id, :string
    field :agent_name, :string
    field :role, :string
    field :model, :string
    field :task_type, :string
    field :success, :boolean
    field :cost_usd, :float
    field :tokens_used, :integer
    field :duration_ms, :integer
    field :project_path, :string
    field :scope_tier, :string
    field :files_touched, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required_fields ~w(team_id agent_name model task_type success)a
  @optional_fields ~w(role cost_usd tokens_used duration_ms project_path scope_tier files_touched)a

  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
