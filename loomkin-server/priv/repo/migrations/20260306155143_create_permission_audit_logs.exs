defmodule Loomkin.Repo.Migrations.CreatePermissionAuditLogs do
  use Ecto.Migration

  def change do
    create table(:permission_audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :team_id, :string, null: false
      add :agent_name, :string, null: false
      add :tool_name, :string, null: false
      add :tool_path, :string
      add :action, :string, null: false
      add :comment, :text
      add :decided_at, :utc_datetime, null: false
    end

    create index(:permission_audit_logs, [:session_id])
    create index(:permission_audit_logs, [:team_id])
    create index(:permission_audit_logs, [:decided_at])
  end
end
