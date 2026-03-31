defmodule Loomkin.Repo.Migrations.CreateWorkspaceInvites do
  use Ecto.Migration

  def change do
    create table(:workspace_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :role, :string, null: false, default: "collaborator"
      add :token, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :invited_by_id,
          references(:users, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_invites, [:token])
    create index(:workspace_invites, [:workspace_id])
    create index(:workspace_invites, [:invited_by_id])
    create index(:workspace_invites, [:email])
    create index(:workspace_invites, [:status])

    create constraint(:workspace_invites, :valid_invite_role,
      check: "role IN ('collaborator', 'observer')"
    )

    create constraint(:workspace_invites, :valid_invite_status,
      check: "status IN ('pending', 'accepted', 'declined', 'expired', 'revoked')"
    )
  end
end
