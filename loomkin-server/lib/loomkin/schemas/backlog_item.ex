defmodule Loomkin.Schemas.BacklogItem do
  @moduledoc """
  Persistent backlog item — a prioritized unit of planned work.

  Replaces the noisy decision graph for tracking goals and roadmap items.
  Unlike decision nodes (which accumulate without cleanup), backlog items
  have explicit lifecycle states and are designed to be curated by the
  concierge and queried by agents.

  ## Status Lifecycle

      icebox → todo → in_progress → done
                ↘ blocked ↗         ↘ cancelled

  ## Priority Scale

  1 = critical (do now), 2 = high, 3 = medium, 4 = low, 5 = someday/maybe
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "backlog_items" do
    field :title, :string
    field :description, :string

    field :status, Ecto.Enum,
      values: [:icebox, :todo, :in_progress, :done, :blocked, :cancelled],
      default: :todo

    field :priority, :integer, default: 3
    field :category, :string
    field :epic, :string
    field :tags, {:array, :string}, default: []

    # Who created and who's working on it
    field :created_by, :string
    field :assigned_to, :string
    field :assigned_team, :string

    # Dependency tracking — references another backlog item ID
    field :depends_on_id, :binary_id
    # Acceptance criteria (list of strings, checked off as completed)
    field :acceptance_criteria, {:array, :string}, default: []
    # Result summary when done
    field :result, :string
    # Estimated scope — aligns with epic-16 envelope tiers
    field :scope_estimate, Ecto.Enum,
      values: [:quick, :session, :campaign],
      default: :session

    # Workspace scoping — nil means global
    belongs_to :workspace, Loomkin.Workspace

    # Optional session link — which session spawned this item
    field :session_id, :binary_id
    # Optional link to decision node that birthed this item
    field :decision_node_id, :binary_id

    # Sort order within priority band
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(title status)a
  @optional_fields ~w(description priority category epic tags created_by assigned_to
    assigned_team depends_on_id acceptance_criteria result scope_estimate
    workspace_id session_id decision_node_id sort_order)a

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:priority, 1..5)
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 10_000)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:depends_on_id, name: :backlog_items_depends_on_id_fkey)
  end
end
