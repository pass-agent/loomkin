defmodule Loomkin.Repo.Migrations.CreateKindredProposals do
  use Ecto.Migration

  def change do
    create_query =
      "CREATE TYPE kindred_proposal_status AS ENUM ('pending', 'approved', 'rejected', 'applied')"

    drop_query = "DROP TYPE kindred_proposal_status"
    execute(create_query, drop_query)

    create table(:kindred_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :proposed_by, :string, null: false
      add :status, :kindred_proposal_status, null: false, default: "pending"
      add :changes, :map, null: false, default: %{}
      add :review_notes, :text
      add :reviewed_at, :utc_datetime

      add :kindred_id,
          references(:kindreds, type: :binary_id, on_delete: :delete_all),
          null: false

      add :reflection_snippet_id,
          references(:snippets, type: :binary_id, on_delete: :nilify_all)

      add :reviewed_by, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:kindred_proposals, [:kindred_id])
    create index(:kindred_proposals, [:status])
  end
end
