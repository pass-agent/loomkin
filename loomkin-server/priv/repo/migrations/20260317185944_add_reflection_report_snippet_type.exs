defmodule Loomkin.Repo.Migrations.AddReflectionReportSnippetType do
  use Ecto.Migration

  def change do
    # Snippet type is stored as a plain string, not a Postgres enum.
    # The new :reflection_report type is handled at the Ecto.Enum layer.
    # This migration exists as a documentation marker only.
  end
end
