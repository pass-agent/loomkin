defmodule Loomkin.Schemas.VaultKanbanItem do
  @moduledoc "Vault kanban item — task board entry for knowledge base operations."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "vault_kanban_items" do
    field :vault_id, :string
    field :description, :string
    field :assignee, :string
    field :project_tag, :string

    field :column, Ecto.Enum,
      values: [:backlog, :next_up, :in_progress, :done, :archived],
      default: :backlog

    field :source_path, :string
    field :completed_at, :utc_datetime
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(vault_id description)a
  @optional_fields ~w(assignee project_tag column source_path completed_at sort_order)a

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:description, max: 1000)
  end
end
