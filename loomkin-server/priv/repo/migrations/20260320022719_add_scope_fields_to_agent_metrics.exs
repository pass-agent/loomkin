defmodule Loomkin.Repo.Migrations.AddScopeFieldsToAgentMetrics do
  use Ecto.Migration

  def change do
    alter table(:agent_metrics) do
      add :scope_tier, :string
      add :files_touched, :integer
    end

    create index(:agent_metrics, [:scope_tier])
  end
end
