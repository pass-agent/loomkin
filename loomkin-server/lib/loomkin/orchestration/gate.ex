defmodule Loomkin.Orchestration.Gate do
  @moduledoc """
  Behaviour for an orchestration review gate.

  A gate is a list of `Loomkin.Orchestration.Reviewer` modules that all must
  pass before the orchestrator advances. Gates fan out reviewers in parallel
  via `Task.Supervisor` and collate their verdicts.

  Returns `{:pass | :fail, [verdict]}`. `:pass` requires every reviewer's
  verdict to be `:pass`. `:fail` returns at the first reviewer error or
  any `:fail` verdict.
  """

  alias Loomkin.Orchestration.Schema.ReviewVerdict

  @type aggregate :: :pass | :fail

  @callback name() :: atom()
  @callback reviewers() :: [module()]
  @callback run(Loomkin.Orchestration.Reviewer.payload(), keyword()) ::
              {aggregate(), [ReviewVerdict.t()]}

  @optional_callbacks []
end
