defmodule Loomkin.Repo.Migrations.CreateDeviceCodes do
  use Ecto.Migration

  def change do
    create table(:device_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_code, :string, null: false
      add :user_code, :string, null: false
      add :client_id, :string, null: false
      add :scope, :string, default: "vault:read vault:write"
      add :user_id, references(:users, type: :id, on_delete: :delete_all)
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :interval, :integer, default: 5
      add :last_polled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_codes, [:device_code])
    create unique_index(:device_codes, [:user_code])
  end
end
