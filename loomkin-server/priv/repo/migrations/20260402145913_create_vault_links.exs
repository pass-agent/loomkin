defmodule Loomkin.Repo.Migrations.CreateVaultLinks do
  use Ecto.Migration

  def change do
    create table(:vault_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, :string, null: false
      add :source_path, :string, null: false
      add :target_path, :string, null: false
      add :link_type, :string, default: "wiki_link"
      add :display_text, :string
      add :context, :string

      timestamps(type: :utc_datetime)
    end

    create index(:vault_links, [:vault_id, :source_path])
    create index(:vault_links, [:vault_id, :target_path])
    create unique_index(:vault_links, [:vault_id, :source_path, :target_path, :link_type])
  end
end
