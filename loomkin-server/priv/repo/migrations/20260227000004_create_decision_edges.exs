defmodule Loomkin.Repo.Migrations.CreateDecisionEdges do
  use Ecto.Migration

  def change do
    create table(:decision_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :change_id, :binary_id, null: false
      add :from_node_id, references(:decision_nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :to_node_id, references(:decision_nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :edge_type, :string, null: false
      add :weight, :float, default: 1.0
      add :rationale, :text

      timestamps(type: :utc_datetime)
    end

    create index(:decision_edges, [:from_node_id])
    create index(:decision_edges, [:to_node_id])
    create index(:decision_edges, [:edge_type])
    create unique_index(:decision_edges, [:change_id])
  end
end
