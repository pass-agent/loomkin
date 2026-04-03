defmodule Loomkin.Repo.Migrations.AddVaultSearchIndex do
  use Ecto.Migration

  def up do
    # Enable pg_trgm for fuzzy search
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # Add tsvector column
    alter table(:vault_entries) do
      add :search_vector, :tsvector
    end

    # GIN index for fast full-text search
    create index(:vault_entries, [:search_vector], using: :gin)

    # Trigger function to auto-update search_vector
    execute """
    CREATE OR REPLACE FUNCTION vault_entries_search_vector_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.tags, ' '), '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.entry_type, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(NEW.body, '')), 'D');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER vault_entries_search_vector_update
    BEFORE INSERT OR UPDATE ON vault_entries
    FOR EACH ROW
    EXECUTE FUNCTION vault_entries_search_vector_trigger();
    """

    # Trigram index on title for fuzzy search
    execute "CREATE INDEX vault_entries_title_trgm ON vault_entries USING GIN (title gin_trgm_ops)"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS vault_entries_search_vector_update ON vault_entries"
    execute "DROP FUNCTION IF EXISTS vault_entries_search_vector_trigger()"
    execute "DROP INDEX IF EXISTS vault_entries_title_trgm"

    alter table(:vault_entries) do
      remove :search_vector
    end

    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
