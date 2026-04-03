defmodule Loomkin.Repo.Migrations.CreateBacklogItems do
  use Ecto.Migration

  def change do
    create table(:backlog_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "todo"
      add :priority, :integer, null: false, default: 3
      add :category, :string
      add :epic, :string
      add :tags, {:array, :string}, default: []
      add :created_by, :string
      add :assigned_to, :string
      add :assigned_team, :string
      add :depends_on_id, references(:backlog_items, type: :binary_id, on_delete: :nilify_all)
      add :acceptance_criteria, {:array, :string}, default: []
      add :result, :text
      add :scope_estimate, :string, default: "session"
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
      add :session_id, :binary_id
      add :decision_node_id, :binary_id
      add :sort_order, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    # Primary query path: status + priority for the concierge to present curated lists
    create index(:backlog_items, [:status, :priority])
    # Filter by category/epic for roadmap views
    create index(:backlog_items, [:category])
    create index(:backlog_items, [:epic])
    # Workspace scoping
    create index(:backlog_items, [:workspace_id])
    # Find items assigned to a specific team
    create index(:backlog_items, [:assigned_team])
    # Dependency lookup
    create index(:backlog_items, [:depends_on_id])
  end
end
