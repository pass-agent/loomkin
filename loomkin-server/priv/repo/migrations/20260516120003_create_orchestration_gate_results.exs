defmodule Loomkin.Repo.Migrations.CreateOrchestrationGateResults do
  use Ecto.Migration

  def change do
    create table(:orchestration_gate_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :verdict, :string, null: false
      add :iteration, :integer, null: false, default: 1
      add :payload_digest, :string
      add :verdicts, {:array, :map}, null: false, default: []

      add :epic_id,
          references(:orchestration_epics, type: :binary_id, on_delete: :delete_all),
          null: false

      add :work_unit_id,
          references(:orchestration_work_units, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_gate_results, [:epic_id, :kind, :iteration])
    create index(:orchestration_gate_results, [:work_unit_id])
  end
end
