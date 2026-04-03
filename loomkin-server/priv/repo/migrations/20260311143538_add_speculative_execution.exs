defmodule Loomkin.Repo.Migrations.AddSpeculativeExecution do
  use Ecto.Migration

  def change do
    alter table(:team_tasks) do
      add :speculative, :boolean, default: false
      add :based_on_tentative, references(:team_tasks, type: :binary_id, on_delete: :nilify_all)
      add :confidence, :decimal, precision: 3, scale: 2, default: 1.0
    end

    create table(:task_assumptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:team_tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :assumption_key, :string, null: false
      add :assumed_value, :text
      add :actual_value, :text
      add :matched, :boolean

      timestamps(type: :utc_datetime)
    end

    create index(:task_assumptions, [:task_id])
  end
end
