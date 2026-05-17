defmodule Loomkin.Orchestration.Schema.ReviewVerdict do
  @moduledoc """
  Embedded schema for a single reviewer's verdict on a gate.

  Adversarial review enforces that the `evidence` list is non-empty and that
  every entry matches the `file:line` form. `Loomkin.Orchestration.Gates.AdversarialReviewGate`
  rejects verdicts that fail this contract regardless of the textual rationale.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @evidence_pattern ~r/^[^\s:]+:\d+/

  @primary_key false
  embedded_schema do
    field :verdict, Ecto.Enum, values: [:pass, :fail]
    field :reviewer, :string
    field :model, :string
    field :evidence, {:array, :string}, default: []
    field :blocking, {:array, :string}, default: []
    field :warnings, {:array, :string}, default: []
    field :rationale, :string
    field :iteration, :integer, default: 1
  end

  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [
      :verdict,
      :reviewer,
      :model,
      :evidence,
      :blocking,
      :warnings,
      :rationale,
      :iteration
    ])
    |> validate_required([:verdict, :reviewer])
    |> validate_evidence_consistency()
  end

  defp validate_evidence_consistency(cs) do
    case get_field(cs, :verdict) do
      :fail ->
        case get_field(cs, :blocking) do
          [] ->
            add_error(cs, :blocking, "fail verdict must list at least one blocking issue")

          _ ->
            cs
        end

      _ ->
        cs
    end
  end

  @doc """
  Returns `:ok` if every evidence entry matches `file:line` form, `{:error, list}`
  otherwise. Used by `Loomkin.Orchestration.Gates.AdversarialReviewGate`.
  """
  @spec validate_evidence([String.t()]) :: :ok | {:error, [String.t()]}
  def validate_evidence([]), do: {:error, ["evidence list is empty"]}

  def validate_evidence(evidence) when is_list(evidence) do
    bad = Enum.reject(evidence, &Regex.match?(@evidence_pattern, &1))

    case bad do
      [] -> :ok
      _ -> {:error, Enum.map(bad, &"evidence entry must match file:line: #{inspect(&1)}")}
    end
  end

  @doc "The regex that valid `file:line` evidence must match."
  def evidence_pattern, do: @evidence_pattern
end
