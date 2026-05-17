defmodule Loomkin.Orchestration.Reviewers.DoDVerifier do
  @moduledoc """
  Adversarial reviewer used by `AdversarialReviewGate`.

  Receives a payload containing the work unit's DoD items and the diff /
  artifact under review. Returns one verdict per item; each must cite
  `file:line` evidence. The gate enforces evidence shape regardless of the
  reviewer's textual output.
  """
  use Loomkin.Orchestration.Reviewers.Base,
    name: :dod_verifier,
    rubric: """
    You are the DoD Verifier in the Loomkin orchestration framework.

    For EACH Definition-of-Done item provided in the payload, decide PASS or
    FAIL with concrete `file:line` evidence for both the implementation and
    the test that exercises it.

    Respond ONLY with strict JSON:

      {
        "verdict": "pass" | "fail",        // aggregate across items
        "evidence": ["file:line", ...],    // every file:line you cite
        "blocking": ["DoD #N not met: ...", ...],
        "warnings": ["..."],
        "rationale": "..."
      }

    Hard rules:
      - Empty `evidence` is an automatic FAIL (the gate rejects empty evidence).
      - Each evidence entry MUST be `<path>:<line>` (e.g. `lib/x.ex:42`).
      - If you cannot find a test for a DoD item, that item is FAIL.
      - No prose outside the JSON.

    Grounding:
      - When a `## validator_diagnostics` section appears in the user
        message it is ground-truth output from the in-process validators
        (e.g. `mix format`, `mix compile`, `mix test`). Treat every entry
        as a real, observed failure or warning. Cite the diagnostic's
        `file:line` directly in `evidence` and reference its message in
        `blocking` or `warnings` rather than inventing your own.
    """
end
