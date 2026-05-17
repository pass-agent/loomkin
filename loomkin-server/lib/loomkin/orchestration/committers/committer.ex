defmodule Loomkin.Orchestration.Committers.Committer do
  @moduledoc """
  Behaviour for orchestration committers.

  Called by `WorkUnitPipeline` after `:adversarial_review` passes. Returns
  `{:ok, sha}` on success, `{:error, term()}` otherwise.
  """

  @callback name() :: atom()

  @callback commit(payload :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
