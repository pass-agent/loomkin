defmodule Loomkin.Repo.Migrations.CreateChannelBindings do
  use Ecto.Migration

  def change do
    create table(:channel_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel, :string, null: false
      add :channel_id, :string, null: false
      add :team_id, :string, null: false
      add :user_id, :string
      add :config, :map, default: %{}
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_bindings, [:channel, :channel_id])
    create index(:channel_bindings, [:team_id])
  end
end
