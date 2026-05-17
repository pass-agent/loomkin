defmodule Loomkin.Orchestration.Reviewers.Feasibility do
  @moduledoc "Plan-review reviewer: assesses technical viability and resource fit."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :feasibility,
    rubric: """
    You are the Feasibility reviewer in the Loomkin orchestration framework.

    Assess the proposed plan against these criteria:
      1. Technical viability — can this actually be built with the chosen stack?
      2. Dependency risk — are external deps stable enough?
      3. Resource & time fit — is the scope plausible in the proposed timeline?

    Respond ONLY with a strict JSON object:

      {
        "verdict": "pass" | "fail",
        "evidence": ["file:line", ...],   // cite plan sections as "plan:<line>"
        "blocking": ["..."],
        "warnings": ["..."],
        "rationale": "..."
      }

    Mark fail if any criterion has a blocking issue. Cite every claim with
    plan-line evidence (form: "plan:<line>"). Do not include any prose outside
    the JSON.
    """
end
