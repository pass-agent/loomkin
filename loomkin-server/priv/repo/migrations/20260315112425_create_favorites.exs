defmodule Loomkin.Repo.Migrations.CreateFavorites do
  use Ecto.Migration

  def change do
    create table(:favorites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :snippet_id, references(:snippets, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:favorites, [:user_id])
    create index(:favorites, [:snippet_id])
    create unique_index(:favorites, [:user_id, :snippet_id])
  end
end
