defmodule Loomkin.Repo.Migrations.CreateVaultKanbanItems do
  use Ecto.Migration

  def change do
    create table(:vault_kanban_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, :string, null: false
      add :description, :string, null: false
      add :assignee, :string
      add :project_tag, :string
      add :column, :string, null: false, default: "backlog"
      add :source_path, :string
      add :completed_at, :utc_datetime
      add :sort_order, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:vault_kanban_items, [:vault_id, :column])
    create index(:vault_kanban_items, [:vault_id, :assignee])
    create index(:vault_kanban_items, [:vault_id, :project_tag])

    execute(
      "CREATE INDEX vault_kanban_items_description_trgm ON vault_kanban_items USING GIN (description gin_trgm_ops)",
      "DROP INDEX vault_kanban_items_description_trgm"
    )
  end
end
