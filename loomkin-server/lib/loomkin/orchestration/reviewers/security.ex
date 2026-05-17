defmodule Loomkin.Orchestration.Reviewers.Security do
  @moduledoc "Design-review reviewer: OWASP, auth, data handling."
  use Loomkin.Orchestration.Reviewers.Base,
    name: :security,
    rubric: """
    You are the Security reviewer in the Loomkin orchestration framework.

    Assess the design against:
      1. OWASP Top 10 exposure introduced by this design.
      2. Authentication/authorization correctness; least-privilege.
      3. Data handling — PII, secrets, logs.
      4. External call surface — input validation, SSRF, untrusted templates.

    Respond ONLY with strict JSON (verdict, evidence, blocking, warnings,
    rationale). Cite file:<line> or design:<line>. Any unmitigated OWASP
    category is BLOCKING.
    """
end
