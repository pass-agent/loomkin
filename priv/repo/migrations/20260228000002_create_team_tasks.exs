defmodule Loomkin.Repo.Migrations.CreateTeamTasks do
  use Ecto.Migration

  def change do
    create table(:team_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "pending"
      add :owner, :string
      add :priority, :integer, default: 3
      add :model_hint, :string
      add :result, :text
      add :cost_usd, :decimal, default: 0
      add :tokens_used, :integer, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:team_tasks, [:team_id])
    create index(:team_tasks, [:status])

    create table(:team_task_deps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:team_tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :depends_on_id, references(:team_tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :dep_type, :string, null: false, default: "blocks"
      timestamps(type: :utc_datetime)
    end

    create index(:team_task_deps, [:task_id])
    create index(:team_task_deps, [:depends_on_id])

    alter table(:decision_nodes) do
      add :agent_name, :string
    end
  end
end
