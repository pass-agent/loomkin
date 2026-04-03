defmodule Loomkin.Repo.Migrations.CreateKinAgents do
  use Ecto.Migration

  def change do
    create table(:kin_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :display_name, :string
      add :role, :string, null: false
      add :auto_spawn, :boolean, default: false, null: false
      add :potency, :integer, default: 50, null: false
      add :spawn_context, :text
      add :model_override, :string
      add :system_prompt_extra, :text
      add :tool_overrides, :map, default: %{}
      add :budget_limit, :integer
      add :tags, {:array, :string}, default: []
      add :enabled, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:kin_agents, [:name])
  end
end
