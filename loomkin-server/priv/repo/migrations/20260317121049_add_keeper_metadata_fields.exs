defmodule Loomkin.Repo.Migrations.AddKeeperMetadataFields do
  use Ecto.Migration

  def change do
    alter table(:context_keepers) do
      add :last_accessed_at, :utc_datetime
      add :access_count, :integer, null: false, default: 0
      add :last_agent_name, :string
      add :retrieval_mode_histogram, :map, null: false, default: %{}
      add :summary, :text
      add :relevance_score, :float, null: false, default: 0.0
      add :confidence, :float, null: false, default: 0.5
      add :success_count, :integer, null: false, default: 0
      add :miss_count, :integer, null: false, default: 0
    end

    create index(:context_keepers, [:last_accessed_at])
  end
end
