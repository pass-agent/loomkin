defmodule Loomkin.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :status, :string, null: false, default: "active"
      add :model, :string, null: false
      add :prompt_tokens, :integer, null: false, default: 0
      add :completion_tokens, :integer, null: false, default: 0
      add :cost_usd, :decimal, null: false, default: 0
      add :summary_message_id, :binary_id
      add :project_path, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:status])
    create index(:sessions, [:project_path])
  end
end
