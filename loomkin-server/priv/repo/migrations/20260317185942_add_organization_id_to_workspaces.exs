defmodule Loomkin.Repo.Migrations.AddOrganizationIdToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workspaces, [:organization_id])
  end
end
