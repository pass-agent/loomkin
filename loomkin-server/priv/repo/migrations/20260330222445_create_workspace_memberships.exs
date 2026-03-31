defmodule Loomkin.Repo.Migrations.CreateWorkspaceMemberships do
  use Ecto.Migration

  def change do
    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "collaborator"
      add :worktree_path, :string
      add :accepted_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :bigint, on_delete: :delete_all),
          null: false

      add :invited_by_id,
          references(:users, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id])
    create index(:workspace_memberships, [:invited_by_id])

    create constraint(:workspace_memberships, :valid_membership_role,
      check: "role IN ('owner', 'collaborator', 'observer')"
    )
  end
end
