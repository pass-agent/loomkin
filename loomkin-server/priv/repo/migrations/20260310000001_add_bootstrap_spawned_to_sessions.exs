defmodule Loomkin.Repo.Migrations.AddBootstrapSpawnedToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :bootstrap_spawned, :boolean, default: false
    end
  end
end
