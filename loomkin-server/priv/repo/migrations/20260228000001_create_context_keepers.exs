defmodule Loomkin.Repo.Migrations.CreateContextKeepers do
  use Ecto.Migration

  def change do
    create table(:context_keepers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, :string, null: false
      add :topic, :string, null: false
      add :source_agent, :string, null: false
      add :messages, :map
      add :token_count, :integer, null: false, default: 0
      add :metadata, :map
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime)
    end

    create index(:context_keepers, [:team_id])
    create index(:context_keepers, [:status])
  end
end
