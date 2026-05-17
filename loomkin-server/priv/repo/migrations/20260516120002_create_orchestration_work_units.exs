defmodule Loomkin.Repo.Migrations.CreateOrchestrationWorkUnits do
  use Ecto.Migration

  def change do
    create table(:orchestration_work_units, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "pending"
      add :file_scope, {:array, :string}, null: false, default: []
      add :deps, {:array, :binary_id}, null: false, default: []
      add :iteration, :integer, null: false, default: 0
      add :assigned_model, :string
      add :commit_sha, :string
      add :dod_items, {:array, :map}, null: false, default: []

      add :epic_id,
          references(:orchestration_epics, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_work_units, [:epic_id])
    create index(:orchestration_work_units, [:status])
  end
end
