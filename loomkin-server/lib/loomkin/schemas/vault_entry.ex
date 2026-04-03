defmodule Loomkin.Schemas.VaultEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_entries" do
    field :vault_id, :string
    field :path, :string
    field :title, :string
    field :entry_type, :string
    field :body, :string
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :checksum, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(vault_id path)a
  @optional_fields ~w(title entry_type body metadata tags checksum)a

  @valid_entry_types ~w(note topic project person decision meeting checkin idea source stream_idea guest_profile okr spec milestone)

  def changeset(vault_entry, attrs) do
    vault_entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:entry_type, @valid_entry_types)
    |> unique_constraint([:vault_id, :path])
  end
end
