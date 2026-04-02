defmodule Loomkin.Repo.Migrations.CreateVaultEntries do
  use Ecto.Migration

  def change do
    create table(:vault_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, :string, null: false
      add :path, :string, null: false
      add :title, :string
      add :entry_type, :string
      add :body, :text
      add :metadata, :map, default: %{}
      add :tags, {:array, :string}, default: []
      add :checksum, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_entries, [:vault_id, :path])
    create index(:vault_entries, [:vault_id, :entry_type])
    create index(:vault_entries, [:vault_id])

    # GIN index for efficient tag array containment queries
    execute(
      "CREATE INDEX vault_entries_tags_gin ON vault_entries USING GIN (tags)",
      "DROP INDEX vault_entries_tags_gin"
    )
  end
end
