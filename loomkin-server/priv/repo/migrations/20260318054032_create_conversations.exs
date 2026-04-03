defmodule Loomkin.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, :string, null: false
      add :topic, :string, null: false
      add :context, :text
      add :spawned_by, :string
      add :turn_strategy, :string
      add :status, :string, null: false, default: "active"
      add :end_reason, :string
      add :current_round, :integer, default: 1
      add :max_rounds, :integer, default: 10
      add :tokens_used, :integer, default: 0
      add :max_tokens, :integer
      add :participants, {:array, :map}, default: []
      add :history, {:array, :map}, default: []
      add :summary, :map
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:team_id])
    create index(:conversations, [:status])
    create index(:conversations, [:team_id, :status])
  end
end
