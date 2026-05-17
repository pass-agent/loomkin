defmodule Loomkin.Repo.Migrations.CreateOrchestrationCostEvents do
  use Ecto.Migration

  def change do
    create table(:orchestration_cost_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :epic_id, :binary_id
      add :model, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cost_usd, :decimal, precision: 18, scale: 8

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_cost_events, [:epic_id])
    create index(:orchestration_cost_events, [:model, :inserted_at])
  end
end
