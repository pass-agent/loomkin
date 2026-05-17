defmodule Loomkin.Repo.Migrations.CreateOrchestrationPhaseMetrics do
  use Ecto.Migration

  def change do
    create table(:orchestration_phase_metrics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :epic_id, :binary_id
      add :work_unit_id, :binary_id
      add :event_kind, :string, null: false
      add :phase, :string
      add :gate, :string
      add :verdict, :string
      add :iteration, :integer, null: false, default: 1
      add :duration_ms, :integer
      add :model, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_phase_metrics, [:epic_id, :inserted_at])
    create index(:orchestration_phase_metrics, [:event_kind, :inserted_at])
    create index(:orchestration_phase_metrics, [:gate, :verdict])
    create index(:orchestration_phase_metrics, [:model])
  end
end
