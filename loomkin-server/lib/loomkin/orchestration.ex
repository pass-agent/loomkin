defmodule Loomkin.Orchestration do
  @moduledoc """
  Loomkin.Orchestration provides a hardened orchestration runtime in
  native Elixir/OTP.

  Top-level facade. The runtime lives under `Loomkin.Orchestration.Supervisor`
  which is started from `Loomkin.Application`. See `docs/orchestration/ARCHITECTURE.md`.

  ## Phases

  An epic flows through these named phases (see `Loomkin.Orchestration.IssueOrchestrator`):

      :research → :plan → :plan_review → :design_review →
      :decompose → :execute → :final_review → :pr → :closure

  Each work unit inside `:execute` runs the 4-phase pipeline
  (see `Loomkin.Orchestration.WorkUnitPipeline`):

      :implement → :validate → :adversarial_review → :commit

  ## Trust-nothing invariants

    * Validators are run by the orchestrator, never by the worker that produced
      the work.
    * `AdversarialReviewGate` rejects any verdict whose evidence does not match
      the `file:line` form.
    * Curator-extracted knowledge facts persist at `:medium` confidence until a
      human or repeat agreement promotes them.
    * Gate iteration is capped at 5 attempts (see
      `Loomkin.Orchestration.RetryLadder`). The 6th attempt emits
      `orchestration.epic.escalated` on the bus and parks the epic.
  """

  alias Loomkin.Orchestration.RetryLadder

  @doc "Returns the list of phase atoms in canonical order."
  @spec phases() :: [atom()]
  def phases do
    [
      :research,
      :plan,
      :plan_review,
      :design_review,
      :decompose,
      :execute,
      :final_review,
      :pr,
      :closure
    ]
  end

  @doc "Returns the list of work-unit phase atoms in canonical order."
  @spec work_unit_phases() :: [atom()]
  def work_unit_phases do
    [:implement, :validate, :adversarial_review, :commit]
  end

  @doc """
  Maximum gate iterations before automatic human escalation.

  Defaults to the length of the `RetryLadder` ladder (5). Configurable via
  `:loomkin, Loomkin.Orchestration, max_gate_iterations: integer()`.
  """
  @spec max_gate_iterations() :: pos_integer()
  def max_gate_iterations do
    Application.get_env(:loomkin, __MODULE__, [])
    |> Keyword.get(:max_gate_iterations, 5)
  end

  @doc """
  Returns the per-attempt knob set for a retry scope. Thin delegate to
  `Loomkin.Orchestration.RetryLadder.knobs/2`.
  """
  @spec attempt_strategy(RetryLadder.scope(), pos_integer()) ::
          RetryLadder.knobs() | :escalate
  def attempt_strategy(scope, attempt), do: RetryLadder.knobs(scope, attempt)
end
