defmodule Loomkin.Schemas.VaultLink do
  @moduledoc "Vault entry link — tracks relationships between entries."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "vault_links" do
    field :vault_id, :string
    field :source_path, :string
    field :target_path, :string

    field :link_type, Ecto.Enum,
      values: [:wiki_link, :parent, :related, :blocks, :follows_up, :decides],
      default: :wiki_link

    field :display_text, :string
    field :context, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(vault_id source_path target_path)a
  @optional_fields ~w(link_type display_text context)a

  def changeset(link, attrs) do
    link
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_no_self_link()
    |> unique_constraint([:vault_id, :source_path, :target_path, :link_type])
  end

  defp validate_no_self_link(changeset) do
    source = get_field(changeset, :source_path)
    target = get_field(changeset, :target_path)

    if source && target && source == target do
      add_error(changeset, :target_path, "cannot link an entry to itself")
    else
      changeset
    end
  end
end
