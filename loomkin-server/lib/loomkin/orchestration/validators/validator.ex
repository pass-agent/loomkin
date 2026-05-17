defmodule Loomkin.Orchestration.Validators.Validator do
  @moduledoc """
  Behaviour for orchestration validators.

  A validator runs inside the orchestrator process — never inside the worker
  that produced the artifact (trust-nothing). Returns one of:

    * `:ok` — clean pass, no diagnostics.
    * `{:ok, [String.t()]}` — pass with warnings. The warnings are surfaced
      to downstream consumers (e.g. the adversarial reviewer) as
      `validator_diagnostics` so they can be cited as evidence rather than
      hallucinated.
    * `{:error, [String.t()]}` — fail. The pipeline retries.

  Every diagnostic string (warning or error) should ideally be in the
  `file:line: message` form so it can be cited as evidence by the adversarial
  review gate.
  """

  @callback name() :: atom()

  @callback validate(payload :: map(), opts :: keyword()) ::
              :ok | {:ok, [String.t()]} | {:error, [String.t()]}
end
