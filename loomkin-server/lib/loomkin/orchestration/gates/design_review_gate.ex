defmodule Loomkin.Orchestration.Gates.DesignReviewGate do
  @moduledoc "Five parallel design reviewers: PM, Architect, Designer, Security, CTO."
  @behaviour Loomkin.Orchestration.Gate

  alias Loomkin.Orchestration.GateRunner

  @reviewers [
    Loomkin.Orchestration.Reviewers.PM,
    Loomkin.Orchestration.Reviewers.Architect,
    Loomkin.Orchestration.Reviewers.Designer,
    Loomkin.Orchestration.Reviewers.Security,
    Loomkin.Orchestration.Reviewers.CTO
  ]

  @impl true
  def name, do: :design_review

  @impl true
  def reviewers, do: @reviewers

  @impl true
  def run(payload, opts \\ []) when is_map(payload) do
    GateRunner.run(@reviewers, payload, opts)
  end
end
