defmodule Loomkin.Repo.Migrations.CreateOrchestrationKnowledgeFacts do
  use Ecto.Migration

  def change do
    create table(:orchestration_knowledge_facts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :fact, :text, null: false
      add :recommendation, :text
      add :confidence, :string, null: false, default: "medium"
      add :provenance, {:array, :map}, null: false, default: []
      add :tags, {:array, :string}, null: false, default: []
      add :affected_files, {:array, :string}, null: false, default: []

      add :source_epic_id,
          references(:orchestration_epics, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_knowledge_facts, [:type])
    create index(:orchestration_knowledge_facts, [:confidence])
    create index(:orchestration_knowledge_facts, [:tags], using: :gin)
    create index(:orchestration_knowledge_facts, [:source_epic_id])
  end
end
