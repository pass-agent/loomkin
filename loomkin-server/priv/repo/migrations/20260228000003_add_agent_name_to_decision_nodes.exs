defmodule Loomkin.Repo.Migrations.AddAgentNameToDecisionNodes do
  use Ecto.Migration

  def change do
    # agent_name column may already exist from migration 20260228000002.
    # Only create the index (idempotent via if_not_exists).
    create_if_not_exists index(:decision_nodes, [:agent_name])
  end
end
