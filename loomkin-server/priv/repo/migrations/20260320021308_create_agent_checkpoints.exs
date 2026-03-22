defmodule Loomkin.Repo.Migrations.CreateAgentCheckpoints do
  use Ecto.Migration

  def change do
    create table(:agent_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all)
      add :agent_name, :string, null: false
      add :team_id, :string, null: false
      add :iteration, :integer, null: false
      add :status, :string, null: false
      add :state_binary, :binary
      add :messages_snapshot, :map
      add :task_context, :map
      add :resume_guidance, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agent_checkpoints, [:team_id, :agent_name, :inserted_at])

    create index(:agent_checkpoints, [:session_id])
  end
end
