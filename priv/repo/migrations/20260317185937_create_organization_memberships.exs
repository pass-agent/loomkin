defmodule Loomkin.Repo.Migrations.CreateOrganizationMemberships do
  use Ecto.Migration

  def change do
    create_query = "CREATE TYPE organization_role AS ENUM ('owner', 'admin', 'member')"
    drop_query = "DROP TYPE organization_role"
    execute(create_query, drop_query)

    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :organization_role, null: false, default: "member"

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:organization_memberships, [:organization_id])
    create index(:organization_memberships, [:user_id])
    create unique_index(:organization_memberships, [:organization_id, :user_id])
  end
end
