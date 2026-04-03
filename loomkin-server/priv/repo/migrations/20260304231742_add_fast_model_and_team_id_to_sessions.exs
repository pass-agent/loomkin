defmodule Loomkin.Repo.Migrations.AddFastModelAndTeamIdToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :fast_model, :string
      add :team_id, :string
    end
  end
end
