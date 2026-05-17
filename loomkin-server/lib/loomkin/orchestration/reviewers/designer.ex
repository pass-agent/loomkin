defmodule Loomkin.Orchestration.Reviewers.Designer do
  @moduledoc "Design-review reviewer: UX, accessibility, copy, affordances."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :designer,
    rubric: """
    You are the Designer reviewer in the Loomkin orchestration framework.

    Assess the design against:
      1. Usability — clear affordances, intuitive flows.
      2. Accessibility — keyboard nav, ARIA roles, color contrast, focus order.
      3. Copy — concise, scannable, error messages actionable.
      4. Responsive behavior.

    Respond ONLY with strict JSON (verdict, evidence, blocking, warnings,
    rationale). Cite file:<line> for components or design:<line> for specs.
    """
end
