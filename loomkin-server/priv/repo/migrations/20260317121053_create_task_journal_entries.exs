defmodule Loomkin.Repo.Migrations.CreateTaskJournalEntries do
  use Ecto.Migration

  def change do
    create table(:task_journal_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_id, :binary_id, null: false
      add :status, :string, null: false
      add :result_summary, :text
      add :checkpoint_json, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:task_journal_entries, [:workspace_id])
    create index(:task_journal_entries, [:task_id])
    create index(:task_journal_entries, [:workspace_id, :task_id])
    create index(:task_journal_entries, [:inserted_at])
  end
end
