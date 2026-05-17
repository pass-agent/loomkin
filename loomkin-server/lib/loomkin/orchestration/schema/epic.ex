defmodule Loomkin.Orchestration.Schema.Epic do
  @moduledoc """
  Top-level unit of orchestration work.

  An epic flows through the 9 named phases of `Loomkin.Orchestration.IssueOrchestrator`.
  It owns a git worktree (`worktree_path`) for the duration of execution and a
  list of `WorkUnit` rows.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Loomkin.Orchestration.Schema.DoDItem

  @statuses ~w(pending in_progress awaiting_human closed failed)a

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_epics" do
    field :title, :string
    field :spec, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :current_phase, :string
    field :priority, :integer, default: 2
    field :worktree_path, :string
    field :base_branch, :string, default: "main"
    field :branch, :string
    field :created_by, :string
    field :metadata, :map, default: %{}

    embeds_many :dod_items, DoDItem, on_replace: :delete

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id title spec)a
  @optional ~w(status current_phase priority worktree_path base_branch branch created_by metadata)a

  def changeset(epic, attrs) do
    epic
    |> cast(attrs, @required ++ @optional)
    |> cast_embed(:dod_items)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
  end

  def statuses, do: @statuses
end
