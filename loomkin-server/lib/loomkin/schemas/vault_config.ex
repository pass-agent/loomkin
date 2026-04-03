defmodule Loomkin.Schemas.VaultConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_configs" do
    field :vault_id, :string
    field :name, :string
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :workspace, Loomkin.Workspace
    belongs_to :organization, Loomkin.Schemas.Organization

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(vault_id name)a
  @optional_fields ~w(description metadata)a

  def changeset(vault_config, attrs) do
    vault_config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:vault_id)
  end
end
