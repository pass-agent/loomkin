defmodule Loomkin.Workspace do
  @moduledoc """
  Ecto schema for workspaces — the persistent layer above sessions that owns team lifetime.

  A workspace persists across session connects/disconnects. Teams run under workspaces,
  not sessions, so agents keep running when a user closes their browser tab.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    field :name, :string
    field :project_paths, {:array, :string}, default: []
    field :team_id, :string
    field :status, Ecto.Enum, values: [:active, :hibernated, :archived], default: :active

    belongs_to :user, Loomkin.Accounts.User, type: :id
    has_many :sessions, Loomkin.Schemas.Session
    has_many :task_journal_entries, Loomkin.Workspace.TaskJournalEntry

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(project_paths team_id status user_id)a

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, [:active, :hibernated, :archived])
  end
end
