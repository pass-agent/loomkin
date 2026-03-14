defmodule Loomkin.Schemas.TeamTask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_tasks" do
    field :team_id, :string
    field :title, :string
    field :description, :string

    field :status, Ecto.Enum,
      values: [
        :pending,
        :assigned,
        :in_progress,
        :completed,
        :failed,
        :ready_for_review,
        :blocked,
        :partially_complete,
        :pending_speculative,
        :completed_tentative,
        :discarded_tentative
      ]

    field :owner, :string
    field :priority, :integer, default: 3
    field :model_hint, :string
    field :result, :string
    field :cost_usd, :decimal, default: 0
    field :tokens_used, :integer, default: 0
    field :milestones_emitted, {:array, :string}, default: []
    field :milestones_required, {:array, :string}, default: []
    field :completed_items, :integer
    field :total_items, :integer
    field :partial_results, :map
    field :speculative, :boolean, default: false
    field :based_on_tentative, :binary_id
    field :confidence, :decimal, default: Decimal.new("1.0")
    field :actions_taken, {:array, :string}, default: []
    field :discoveries, {:array, :string}, default: []
    field :files_changed, {:array, :string}, default: []
    field :decisions_made, {:array, :string}, default: []
    field :open_questions, {:array, :string}, default: []
    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(team_id title status)a
  @optional_fields ~w(description owner priority model_hint result cost_usd tokens_used milestones_emitted milestones_required completed_items total_items partial_results speculative based_on_tentative confidence actions_taken discoveries files_changed decisions_made open_questions)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:based_on_tentative, name: :team_tasks_based_on_tentative_fkey)
  end
end
