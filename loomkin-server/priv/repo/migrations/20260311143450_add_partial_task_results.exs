defmodule Loomkin.Repo.Migrations.AddPartialTaskResults do
  use Ecto.Migration

  def change do
    alter table(:team_tasks) do
      add :completed_items, :integer
      add :total_items, :integer
      add :partial_results, :map
    end
  end
end
