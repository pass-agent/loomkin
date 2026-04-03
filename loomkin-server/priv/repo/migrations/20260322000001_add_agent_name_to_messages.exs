defmodule Loomkin.Repo.Migrations.AddAgentNameToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :agent_name, :string
    end
  end
end
