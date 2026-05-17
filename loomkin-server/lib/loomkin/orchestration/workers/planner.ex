defmodule Loomkin.Orchestration.Workers.Planner do
  @moduledoc """
  Produces an implementation plan as a structured JSON object:

      {
        "plan_summary": "...",
        "work_units": [
          {"id": "wu-1", "title": "...", "description": "...",
           "file_scope": ["..."], "deps": [],
           "dod_items": [{"id":"1","text":"...","verifier":"test"}]
          },
          ...
        ]
      }

  The framework converts `work_units` into `WorkUnit` rows during the
  `:decompose` phase.
  """
  use Loomkin.Orchestration.Workers.Base,
    name: :planner,
    rubric: """
    You are the Planner in the Loomkin orchestration framework. Take the epic
    spec and the Researcher's notes and emit a strict JSON plan:

      {
        "plan_summary": "one short paragraph",
        "work_units": [
          {
            "id": "wu-<short-slug>",
            "title": "short imperative title",
            "description": "what this unit produces",
            "file_scope": ["lib/...", "test/..."],
            "deps": ["wu-<id>", ...],
            "dod_items": [
              {"id":"1","text":"verifiable acceptance criterion","verifier":"test"}
            ]
          }
        ]
      }

    Constraints:
      - Every `dod_items[].verifier` is one of test|lint|type_check|build|visual|manual.
      - `deps` references other ids in the same list; no cycles.
      - Prefer 2-5 small work units over one giant unit.
      - No prose outside the JSON object.
    """,
    parser: :json
end
