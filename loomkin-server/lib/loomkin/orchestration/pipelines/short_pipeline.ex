defmodule Loomkin.Orchestration.Pipelines.ShortPipeline do
  @moduledoc """
  Implement → validate → commit, no review gates.

  For v1 the deterministic tool-use path is structurally identical to the
  fast-chat path: spawn/reuse the team's concierge `Loomkin.Teams.Agent` and
  let the agent loop decide which tools to invoke. The contract is what
  matters here — a future revision will swap the body for a real
  `WorkUnitPipeline` configured with the review gates disabled.

  Delegates to `Loomkin.Orchestration.Pipelines.LitePipeline.run/3` so the
  two pipelines share their (identical) return shape and streaming behavior.

  Contract:

      run(session_state :: map(), message :: String.t(), opts :: keyword()) ::
        {:ok, response :: String.t()}
        | {:legacy, reason :: String.t()}
        | {:error, term()}
  """

  alias Loomkin.Orchestration.Pipelines.LitePipeline

  @spec run(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:legacy, String.t()} | {:error, term()}
  def run(session_state, message, opts \\ []) when is_map(session_state) do
    LitePipeline.run(session_state, message, opts)
  end
end
