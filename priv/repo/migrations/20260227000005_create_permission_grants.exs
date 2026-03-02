defmodule Loomkin.Repo.Migrations.CreatePermissionGrants do
  use Ecto.Migration

  def change do
    create table(:permission_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :tool, :string, null: false
      add :scope, :string, null: false, default: "*"
      add :granted_at, :utc_datetime, null: false
    end

    create index(:permission_grants, [:session_id])
    create index(:permission_grants, [:tool])
    create unique_index(:permission_grants, [:session_id, :tool, :scope])
  end
end
