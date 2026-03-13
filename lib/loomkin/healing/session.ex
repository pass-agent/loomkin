defmodule Loomkin.Healing.Session do
  @moduledoc """
  Data structure representing an individual healing session.

  Tracks the lifecycle of a single heal-diagnose-fix-resume cycle
  for a suspended agent.
  """

  @type status ::
          :diagnosing
          | :fixing
          | :complete
          | :failed
          | :timed_out
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          team_id: String.t(),
          agent_name: atom() | String.t(),
          classification: map(),
          error_context: map(),
          status: status(),
          diagnosis: map() | nil,
          fix_result: map() | nil,
          diagnostician_pid: pid() | nil,
          fixer_pid: pid() | nil,
          started_at: DateTime.t(),
          budget_remaining_usd: float(),
          max_iterations: non_neg_integer(),
          attempts: non_neg_integer(),
          max_attempts: non_neg_integer()
        }

  defstruct [
    :id,
    :team_id,
    :agent_name,
    :classification,
    :error_context,
    :status,
    :diagnosis,
    :fix_result,
    :diagnostician_pid,
    :fixer_pid,
    :started_at,
    budget_remaining_usd: 0.50,
    max_iterations: 15,
    attempts: 0,
    max_attempts: 2
  ]
end
