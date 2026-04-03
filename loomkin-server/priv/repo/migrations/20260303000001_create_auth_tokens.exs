defmodule Loomkin.Repo.Migrations.CreateAuthTokens do
  use Ecto.Migration

  def change do
    create table(:auth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :access_token_encrypted, :binary, null: false
      add :refresh_token_encrypted, :binary
      add :expires_at, :utc_datetime
      add :account_id, :string
      add :scopes, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:auth_tokens, [:provider])
  end
end
