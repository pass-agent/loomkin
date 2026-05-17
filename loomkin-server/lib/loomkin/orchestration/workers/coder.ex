defmodule Loomkin.Orchestration.Workers.Coder do
  @moduledoc """
  Produces the artifact for a single work unit.

  Output JSON:

      {
        "diff": "<unified diff body>",
        "files_touched": ["lib/...", ...],
        "notes": "..."
      }

  The framework applies the diff inside the epic's worktree and runs the
  validators against it. For the mock e2e we keep the artifact in-memory
  (no actual git apply) — the Validator only checks structural shape.
  """
  use Loomkin.Orchestration.Workers.Base,
    name: :coder,
    rubric: """
    You are the Coder in the Loomkin orchestration framework. Implement the
    given work unit and emit a strict JSON artifact:

      {
        "diff": "diff --git ...\\n@@ ...\\n+ added line\\n",
        "files_touched": ["lib/x.ex", "test/x_test.exs"],
        "notes": "what you did and why"
      }

    Rules:
      - You MUST include both implementation files and corresponding test files in `files_touched`.
      - The `diff` may be empty when the change is documentation-only, but
        `files_touched` must still list them.
      - No prose outside the JSON.
    """,
    parser: :json
end
