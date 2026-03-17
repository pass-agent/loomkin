defmodule Loomkin.Repo.Migrations.AllowNullableSnippetUserId do
  use Ecto.Migration

  def change do
    # System-generated content (e.g. reflection reports from milestone triggers)
    # may not have an associated user.
    alter table(:snippets) do
      modify :user_id, references(:users, on_delete: :delete_all),
        null: true,
        from: {references(:users, on_delete: :delete_all), null: false}
    end
  end
end
