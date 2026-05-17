defmodule Loomkin.Repo.Migrations.AddExternalIdToKnowledgeFacts do
  use Ecto.Migration

  def change do
    alter table(:orchestration_knowledge_facts) do
      add :external_id, :string
    end

    create unique_index(:orchestration_knowledge_facts, [:external_id],
             where: "external_id IS NOT NULL",
             name: "orch_kf_external_id_unique"
           )
  end
end
