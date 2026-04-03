defmodule Loomkin.Repo.Migrations.CreateSnippets do
  use Ecto.Migration

  def change do
    create table(:snippets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :forked_from_id, references(:snippets, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :type, :string, null: false
      add :visibility, :string, null: false, default: "private"
      add :content, :map, null: false, default: %{}
      add :tags, {:array, :string}, null: false, default: []
      add :slug, :string, null: false
      add :fork_count, :integer, null: false, default: 0
      add :favorite_count, :integer, null: false, default: 0
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:snippets, [:user_id])
    create index(:snippets, [:type])
    create index(:snippets, [:visibility])
    create index(:snippets, [:forked_from_id])
    create unique_index(:snippets, [:user_id, :slug])
  end
end
