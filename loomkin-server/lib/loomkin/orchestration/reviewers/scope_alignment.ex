defmodule Loomkin.Orchestration.Reviewers.ScopeAlignment do
  @moduledoc "Plan-review reviewer: ensures the plan stays in scope and follows conventions."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :scope_alignment,
    rubric: """
    You are the Scope & Alignment reviewer in the Loomkin orchestration
    framework.

    Assess the plan against:
      1. Scope drift — does the plan add work outside the epic spec?
      2. Convention adherence — does it follow the codebase's existing patterns?
      3. Out-of-scope refactors smuggled into a feature plan.

    Respond ONLY with strict JSON (verdict, evidence, blocking, warnings,
    rationale). Cite scope drift with plan:<line> or file:<line> evidence.
    """
end
