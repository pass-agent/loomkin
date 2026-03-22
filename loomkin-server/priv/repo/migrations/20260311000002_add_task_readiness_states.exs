defmodule Loomkin.Repo.Migrations.AddTaskReadinessStates do
  use Ecto.Migration

  def change do
    # The status column is a plain :string — Ecto.Enum handles validation
    # at the application level, so no DB-level column change is needed.
    # We add a composite index for efficient team+status queries.
    create index(:team_tasks, [:team_id, :status])
  end
end
