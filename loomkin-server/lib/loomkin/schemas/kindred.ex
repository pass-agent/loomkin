defmodule Loomkin.Schemas.Kindred do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kindreds" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :version, :integer, default: 1
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :owner_type, Ecto.Enum, values: [:user, :organization]
    field :metadata, :map, default: %{}

    belongs_to :user, Loomkin.Accounts.User, type: :id
    belongs_to :organization, Loomkin.Schemas.Organization
    belongs_to :parent_kindred, __MODULE__

    has_many :items, Loomkin.Schemas.KindredItem
    has_many :proposals, Loomkin.Schemas.KindredProposal

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name owner_type)a
  @optional_fields ~w(slug description version status metadata user_id organization_id parent_kindred_id)a

  def changeset(kindred, attrs) do
    kindred
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 2000)
    |> validate_number(:version, greater_than: 0)
    |> maybe_generate_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$/,
      message: "must be URL-safe: lowercase letters, numbers, hyphens, underscores"
    )
    |> validate_owner_consistency()
    |> unique_constraint([:user_id, :slug])
    |> unique_constraint([:organization_id, :slug])
    |> check_constraint(:kindreds_owner_check,
      name: :kindreds_owner_check,
      message: "exactly one of user_id or organization_id must be set"
    )
  end

  defp validate_owner_consistency(changeset) do
    owner_type = get_field(changeset, :owner_type)
    user_id = get_field(changeset, :user_id)
    org_id = get_field(changeset, :organization_id)

    case owner_type do
      :user when is_nil(user_id) ->
        add_error(changeset, :user_id, "must be set when owner_type is :user")

      :organization when is_nil(org_id) ->
        add_error(changeset, :organization_id, "must be set when owner_type is :organization")

      _ ->
        changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        name = get_change(changeset, :name) || get_field(changeset, :name)

        if name && get_field(changeset, :slug) in [nil, ""] do
          put_change(changeset, :slug, slugify(name))
        else
          changeset
        end

      _slug ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end
end
