defmodule Loomkin.Repo.Migrations.AddDynamicTaskDeps do
  use Ecto.Migration

  def change do
    alter table(:team_tasks) do
      add :milestones_emitted, {:array, :string}, default: []
      add :milestones_required, {:array, :string}, default: []
    end

    alter table(:team_task_deps) do
      add :milestone_name, :string
    end
  end
end
