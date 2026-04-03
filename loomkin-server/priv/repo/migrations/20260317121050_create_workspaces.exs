defmodule Loomkin.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :project_paths, {:array, :string}, null: false, default: []
      add :team_id, :string
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint)

      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:team_id])
    create index(:workspaces, [:status])
    create index(:workspaces, [:inserted_at])
    create index(:workspaces, [:user_id])
    create index(:workspaces, [:project_paths], using: :gin)

    create constraint(:workspaces, :valid_status,
      check: "status IN ('active', 'hibernated', 'archived')"
    )

    create unique_index(:workspaces, [:user_id, :name])
  end
end
