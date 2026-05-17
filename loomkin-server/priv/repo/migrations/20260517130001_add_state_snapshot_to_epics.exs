defmodule Loomkin.Repo.Migrations.AddStateSnapshotToEpics do
  use Ecto.Migration

  def change do
    alter table(:orchestration_epics) do
      add :state_snapshot, :map, null: false, default: %{}
      add :last_phase, :string
      add :last_iteration, :integer
    end
  end
end
