defmodule Loomkin.Repo.Migrations.AddNotNullToBootstrapSpawned do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      modify :bootstrap_spawned, :boolean, null: false, default: false
    end
  end
end
