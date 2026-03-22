defmodule Loomkin.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text
      add :tool_calls, :map
      add :tool_call_id, :string
      add :token_count, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:session_id])
    create index(:messages, [:role])
  end
end
