defmodule Loomkin.Repo.Migrations.CreateOrchestrationEpics do
  use Ecto.Migration

  def change do
    create table(:orchestration_epics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :spec, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :current_phase, :string
      add :priority, :integer, null: false, default: 2
      add :worktree_path, :string
      add :base_branch, :string, null: false, default: "main"
      add :branch, :string
      add :created_by, :string
      add :metadata, :map, null: false, default: %{}
      add :dod_items, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_epics, [:status])
    create index(:orchestration_epics, [:priority, :inserted_at])
  end
end
