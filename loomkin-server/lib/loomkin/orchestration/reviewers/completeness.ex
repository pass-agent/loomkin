defmodule Loomkin.Orchestration.Reviewers.Completeness do
  @moduledoc "Plan-review reviewer: checks for DoD coverage and missing work units."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :completeness,
    rubric: """
    You are the Completeness reviewer in the Loomkin orchestration framework.

    Assess the plan against these criteria:
      1. Every Definition-of-Done item from the epic has at least one work unit
         covering it.
      2. Edge cases relevant to the spec are addressed.
      3. No phase of the standard 9-phase pipeline is silently skipped.

    Respond ONLY with strict JSON:

      {
        "verdict": "pass" | "fail",
        "evidence": ["plan:<line>" | "file:<line>", ...],
        "blocking": ["..."],
        "warnings": ["..."],
        "rationale": "..."
      }

    Fail if any DoD item is uncovered. Cite the missing coverage explicitly.
    No prose outside the JSON.
    """
end
