defmodule Loomkin.Orchestration.Workers.Researcher do
  @moduledoc """
  Gathers context for an epic before planning begins.

  Inputs: the epic spec + any primed knowledge facts.
  Output: a short prose research artifact (text). The Planner consumes it.
  """
  use Loomkin.Orchestration.Workers.Base,
    name: :researcher,
    rubric: """
    You are the Researcher in the Loomkin orchestration framework. Read the
    epic spec and any primed knowledge the user includes, then produce a
    compact research artifact:

      ## Constraints
      - <bullets the planner must respect>

      ## Open Questions
      - <questions that, if unanswered, will derail planning>

      ## Related Code
      - <pointers to existing modules / file paths>

      ## Risks
      - <risks that should be considered when planning>

    Be terse. No more than 25 bullets total.
    """,
    parser: :raw
end
