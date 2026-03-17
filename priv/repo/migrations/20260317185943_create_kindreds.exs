defmodule Loomkin.Repo.Migrations.CreateKindreds do
  use Ecto.Migration

  def change do
    create_status = "CREATE TYPE kindred_status AS ENUM ('draft', 'active', 'archived')"
    drop_status = "DROP TYPE kindred_status"
    execute(create_status, drop_status)

    create_owner = "CREATE TYPE kindred_owner_type AS ENUM ('user', 'organization')"
    drop_owner = "DROP TYPE kindred_owner_type"
    execute(create_owner, drop_owner)

    create_item =
      "CREATE TYPE kindred_item_type AS ENUM ('kin_config', 'skill_ref', 'prompt_template')"

    drop_item = "DROP TYPE kindred_item_type"
    execute(create_item, drop_item)

    create table(:kindreds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :version, :integer, null: false, default: 1
      add :status, :kindred_status, null: false, default: "draft"
      add :owner_type, :kindred_owner_type, null: false
      add :metadata, :map, default: %{}

      add :user_id, references(:users, on_delete: :delete_all)

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all)

      add :parent_kindred_id,
          references(:kindreds, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:kindreds, [:user_id])
    create index(:kindreds, [:organization_id])
    create index(:kindreds, [:status])
    create unique_index(:kindreds, [:user_id, :slug], where: "user_id IS NOT NULL")

    create unique_index(:kindreds, [:organization_id, :slug],
             where: "organization_id IS NOT NULL"
           )

    # Check constraint: exactly one of user_id/organization_id must be set
    create constraint(:kindreds, :kindreds_owner_check,
             check:
               "(user_id IS NOT NULL AND organization_id IS NULL) OR (user_id IS NULL AND organization_id IS NOT NULL)"
           )

    create table(:kindred_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_type, :kindred_item_type, null: false
      add :position, :integer, null: false, default: 0
      add :content, :map, null: false, default: %{}

      add :kindred_id,
          references(:kindreds, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_snippet_id,
          references(:snippets, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:kindred_items, [:kindred_id])
    create index(:kindred_items, [:kindred_id, :position])
  end
end
