defmodule Loomkin.Schemas.Snippet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "snippets" do
    belongs_to :user, Loomkin.Accounts.User, type: :id
    belongs_to :forked_from, __MODULE__

    field :title, :string
    field :description, :string
    field :type, Ecto.Enum, values: [:skill, :prompt, :kin_agent, :chat_log]
    field :visibility, Ecto.Enum, values: [:private, :unlisted, :public], default: :private
    field :content, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :slug, :string
    field :fork_count, :integer, default: 0
    field :favorite_count, :integer, default: 0
    field :version, :integer, default: 1

    has_many :favorites, Loomkin.Schemas.Favorite
    has_many :forks, __MODULE__, foreign_key: :forked_from_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(title type)a
  @optional_fields ~w(description visibility content tags slug forked_from_id version)a

  def changeset(snippet, attrs) do
    snippet
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 2000)
    |> maybe_generate_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$/,
      message: "must be URL-safe: lowercase letters, numbers, hyphens, underscores"
    )
    |> unique_constraint([:user_id, :slug])
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        # Generate slug from title change, or fall back to existing title for new records
        title = get_change(changeset, :title) || get_field(changeset, :title)

        if title && get_field(changeset, :slug) in [nil, ""] do
          put_change(changeset, :slug, slugify(title))
        else
          changeset
        end

      _slug ->
        changeset
    end
  end

  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end
end
