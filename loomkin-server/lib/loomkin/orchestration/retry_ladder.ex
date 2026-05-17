defmodule Loomkin.Orchestration.RetryLadder do
  @moduledoc """
  Per-attempt knob set for orchestration retries.

  Default 5-attempt ladder:

    1. `:default`            — no overrides
    2. `:with_prior_failure` — writer prompt prepended with the prior verdict
    3. `:boost_effort`       — bump `reasoning_effort` / thinking budget
    4. `:swap_model`         — pick the next model in the configured fallback pool
    5. `:prime_with_facts`   — include curator facts about prior failures

  Attempt `max_attempts/1 + 1` (the 6th attempt by default) returns `:escalate`,
  signalling that the orchestrator should bail to human review rather than spin
  again. Per-scope overrides come from the application config:

      config :loomkin, Loomkin.Orchestration,
        retry_ladder: [
          gate:      [%{strategy: :default, ...}, ...],
          work_unit: [%{strategy: :default, ...}, ...]
        ]

  Each entry must be a fully-populated knob map matching `t:knobs/0`. The list
  length defines `max_attempts/1`.
  """

  @type scope :: :gate | :work_unit
  @type strategy ::
          :default
          | :with_prior_failure
          | :boost_effort
          | :swap_model
          | :prime_with_facts

  @type knobs :: %{
          strategy: strategy(),
          model: String.t() | nil,
          reasoning_effort: :low | :medium | :high | nil,
          include_prior_failure: boolean(),
          include_primed_facts: boolean()
        }

  @default_ladder [
    %{
      strategy: :default,
      model: nil,
      reasoning_effort: nil,
      include_prior_failure: false,
      include_primed_facts: false
    },
    %{
      strategy: :with_prior_failure,
      model: nil,
      reasoning_effort: nil,
      include_prior_failure: true,
      include_primed_facts: false
    },
    %{
      strategy: :boost_effort,
      model: nil,
      reasoning_effort: :high,
      include_prior_failure: true,
      include_primed_facts: false
    },
    %{
      strategy: :swap_model,
      model: :next_in_pool,
      reasoning_effort: :high,
      include_prior_failure: true,
      include_primed_facts: false
    },
    %{
      strategy: :prime_with_facts,
      model: :next_in_pool,
      reasoning_effort: :high,
      include_prior_failure: true,
      include_primed_facts: true
    }
  ]

  @doc """
  Returns the knob set for `attempt` in `scope`, or `:escalate` once the cap is
  exceeded. `attempt` is 1-indexed: the very first try is attempt 1.
  """
  @spec knobs(scope(), pos_integer()) :: knobs() | :escalate
  def knobs(scope, attempt)
      when scope in [:gate, :work_unit] and is_integer(attempt) and attempt >= 1 do
    ladder = ladder_for(scope)

    case Enum.at(ladder, attempt - 1) do
      nil -> :escalate
      knobs -> knobs
    end
  end

  @doc """
  Maximum number of attempts (i.e. ladder length) for the given scope.
  """
  @spec max_attempts(scope()) :: pos_integer()
  def max_attempts(scope) when scope in [:gate, :work_unit] do
    length(ladder_for(scope))
  end

  @doc """
  Returns the default ladder. Exposed for tests/config consumers that want to
  build overrides on top of the canonical rungs.
  """
  @spec default_ladder() :: [knobs()]
  def default_ladder, do: @default_ladder

  ## Internals

  defp ladder_for(scope) do
    overrides =
      Application.get_env(:loomkin, Loomkin.Orchestration, [])
      |> Keyword.get(:retry_ladder, [])

    case Keyword.get(overrides, scope) do
      nil -> @default_ladder
      list when is_list(list) and list != [] -> list
      _ -> @default_ladder
    end
  end
end
