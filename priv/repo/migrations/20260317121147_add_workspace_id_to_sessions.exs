defmodule Loomkin.Repo.Migrations.AddWorkspaceIdToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sessions, [:workspace_id])
  end
end
