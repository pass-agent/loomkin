defmodule Loomkin.Repo.Migrations.CreateAgentMetrics do
  use Ecto.Migration

  def change do
    create table(:agent_metrics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, :string, null: false
      add :agent_name, :string, null: false
      add :role, :string
      add :model, :string, null: false
      add :task_type, :string, null: false
      add :success, :boolean, null: false
      add :cost_usd, :float
      add :tokens_used, :integer
      add :duration_ms, :integer
      add :project_path, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:agent_metrics, [:model, :task_type])
    create index(:agent_metrics, [:task_type])
    create index(:agent_metrics, [:team_id])
    create index(:agent_metrics, [:agent_name])
  end
end
