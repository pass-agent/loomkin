defmodule Loomkin.Repo.Migrations.CreateSessionShares do
  use Ecto.Migration

  def change do
    create table(:session_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false
      add :label, :string
      add :permission, :string, null: false, default: "view"
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:session_shares, [:token_hash], unique: true)
    create index(:session_shares, [:session_id])
  end
end
