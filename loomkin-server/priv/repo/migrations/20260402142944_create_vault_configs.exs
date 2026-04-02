defmodule Loomkin.Repo.Migrations.CreateVaultConfigs do
  use Ecto.Migration

  def change do
    create table(:vault_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :storage_type, :string, null: false, default: "local"
      add :storage_config, :map, default: %{}
      add :metadata, :map, default: %{}
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_configs, [:vault_id])
    create index(:vault_configs, [:workspace_id])
  end
end
