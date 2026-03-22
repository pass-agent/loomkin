defmodule Loomkin.Repo.Migrations.AddUserIdToExistingTables do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:kin_agents) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:auth_tokens) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:permission_grants) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:sessions, [:user_id])
    create index(:kin_agents, [:user_id])
    create index(:auth_tokens, [:user_id])
    create index(:permission_grants, [:user_id])
  end
end
