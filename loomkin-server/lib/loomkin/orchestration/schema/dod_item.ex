defmodule Loomkin.Orchestration.Schema.DoDItem do
  @moduledoc """
  Embedded schema for a Definition-of-Done item attached to an epic or work unit.

  Each item is a single, independently verifiable acceptance criterion. The
  `verifier` field hints at how it should be checked (e.g. `:test`, `:visual`,
  `:lint`, `:manual`) but the orchestrator's adversarial review gate ultimately
  enforces evidence regardless of hint.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @verifiers ~w(test lint type_check build visual manual)a

  @primary_key false
  embedded_schema do
    field :id, :string
    field :text, :string
    field :verifier, Ecto.Enum, values: @verifiers, default: :test
    field :file_scope, {:array, :string}, default: []
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:id, :text, :verifier, :file_scope])
    |> validate_required([:id, :text])
  end

  @doc "List of valid verifier atoms."
  def verifiers, do: @verifiers
end
