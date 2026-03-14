defmodule Loomkin.Repo.Migrations.AddStructuredTaskResults do
  use Ecto.Migration

  def change do
    alter table(:team_tasks) do
      add :actions_taken, {:array, :text}, default: []
      add :discoveries, {:array, :text}, default: []
      add :files_changed, {:array, :text}, default: []
      add :decisions_made, {:array, :text}, default: []
      add :open_questions, {:array, :text}, default: []
    end
  end
end
