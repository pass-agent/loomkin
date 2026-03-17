defmodule Loomkin.Workspace.TaskJournalEntry do
  @moduledoc """
  Persistent log of task state changes within a workspace.

  On workspace resumption, in-progress tasks can be rebuilt from the journal.
  Each entry captures a snapshot of task state at a point in time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_journal_entries" do
    field :task_id, :binary_id
    field :status, :string
    field :result_summary, :string
    field :checkpoint_json, :map, default: %{}

    belongs_to :workspace, Loomkin.Workspace

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(workspace_id task_id status)a
  @optional_fields ~w(result_summary checkpoint_json)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workspace_id)
  end
end
