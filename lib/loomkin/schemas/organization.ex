defmodule Loomkin.Schemas.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :avatar_url, :string
    field :settings, :map, default: %{}

    has_many :memberships, Loomkin.Schemas.OrganizationMembership
    has_many :workspaces, Loomkin.Workspace
    has_many :kindreds, Loomkin.Schemas.Kindred

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(slug description avatar_url settings)a

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 2000)
    |> maybe_generate_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$/,
      message: "must be URL-safe: lowercase letters, numbers, hyphens, underscores"
    )
    |> unique_constraint(:slug)
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
