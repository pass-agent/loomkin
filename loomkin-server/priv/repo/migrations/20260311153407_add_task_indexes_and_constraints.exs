defmodule Loomkin.Repo.Migrations.AddTaskIndexesAndConstraints do
  use Ecto.Migration

  def change do
    create index(:team_tasks, [:based_on_tentative])

    create unique_index(:team_task_deps, [:task_id, :depends_on_id, :dep_type],
             name: :team_task_deps_task_id_depends_on_id_dep_type_index
           )

    alter table(:team_tasks) do
      modify :milestones_emitted, {:array, :string}, null: false, default: []
    end
  end
end
