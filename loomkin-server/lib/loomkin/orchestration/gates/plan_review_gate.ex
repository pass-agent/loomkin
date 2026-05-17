defmodule Loomkin.Orchestration.Gates.PlanReviewGate do
  @moduledoc "Three parallel plan reviewers: feasibility, completeness, scope."
  @behaviour Loomkin.Orchestration.Gate

  alias Loomkin.Orchestration.GateRunner

  @reviewers [
    Loomkin.Orchestration.Reviewers.Feasibility,
    Loomkin.Orchestration.Reviewers.Completeness,
    Loomkin.Orchestration.Reviewers.ScopeAlignment
  ]

  @impl true
  def name, do: :plan_review

  @impl true
  def reviewers, do: @reviewers

  @impl true
  def run(payload, opts \\ []) when is_map(payload) do
    GateRunner.run(@reviewers, payload, opts)
  end
end
