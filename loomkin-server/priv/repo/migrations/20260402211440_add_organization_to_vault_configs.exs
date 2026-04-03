defmodule Loomkin.Repo.Migrations.AddOrganizationToVaultConfigs do
  use Ecto.Migration

  def change do
    alter table(:vault_configs) do
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:vault_configs, [:organization_id])
  end
end
