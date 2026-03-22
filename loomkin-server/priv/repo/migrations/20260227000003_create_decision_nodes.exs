defmodule Loomkin.Repo.Migrations.CreateDecisionNodes do
  use Ecto.Migration

  def change do
    create table(:decision_nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :change_id, :binary_id, null: false
      add :node_type, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :confidence, :integer
      add :metadata, :map, default: %{}
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:decision_nodes, [:node_type])
    create index(:decision_nodes, [:status])
    create index(:decision_nodes, [:session_id])
    create unique_index(:decision_nodes, [:change_id])
  end
end
