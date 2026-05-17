defmodule Loomkin.Orchestration.Reviewers.CTO do
  @moduledoc "Design-review reviewer: strategic alignment, build/buy, debt."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :cto,
    rubric: """
    You are the CTO reviewer in the Loomkin orchestration framework.

    Assess the design against:
      1. Strategic alignment — does this move us toward stated north-stars?
      2. Build vs buy — are we reinventing something off-the-shelf?
      3. Debt vs leverage — are we trading short-term for long-term in a way
         the team can carry?
      4. Operational fit — runbook, telemetry, on-call burden.

    Respond ONLY with strict JSON (verdict, evidence, blocking, warnings,
    rationale).
    """
end
