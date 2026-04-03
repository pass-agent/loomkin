defmodule Loomkin.Teams.ScopeDetector do
  @moduledoc """
  Estimates the scope tier for a task based on available signals.

  Scope tiers control budget envelopes and infrastructure escalation:
  - `:quick` — ~1-3 files, isolated change, low coupling
  - `:session` — ~4-15 files, moderate coupling, multiple modules
  - `:campaign` — 15+ files, cross-module, new deps, many tests
  """

  @type tier :: :quick | :session | :campaign

  @type estimate :: %{files: non_neg_integer(), estimated_cost: float()}

  @type signals :: %{
          optional(:task_description) => String.t(),
          optional(:file_matches) => non_neg_integer(),
          optional(:plan_doc) => boolean(),
          optional(:explicit_scope) => tier()
        }

  @quick_keywords ~w(fix update tweak rename typo patch bump)
  @session_keywords ~w(add create endpoint feature test component hook)
  @campaign_keywords ~w(implement refactor epic migrate overhaul rewrite redesign)
  @campaign_phrases ["take your time", "be thorough", "heading to bed", "no rush"]

  @envelopes %{
    quick: %{max_files: 3, max_cost: 0.50},
    session: %{max_files: 15, max_cost: 5.00},
    campaign: %{max_files: 50, max_cost: 50.00}
  }

  # --- Public API ---

  @doc """
  Classify the scope tier from a map of signals.

  Returns `{:ok, tier, estimate}` where estimate includes projected file count
  and estimated cost.
  """
  @spec detect_tier(signals()) :: {:ok, tier(), estimate()}
  def detect_tier(signals) when is_map(signals) do
    tier = classify(signals)
    envelope = tier_envelope(tier)

    estimate = %{
      files: estimate_files(signals, tier),
      estimated_cost: envelope.max_cost * 0.5
    }

    {:ok, tier, estimate}
  end

  @doc """
  Return the budget envelope for a given scope tier.
  """
  @spec tier_envelope(tier()) :: %{max_files: pos_integer(), max_cost: float()}
  def tier_envelope(tier) when tier in [:quick, :session, :campaign] do
    Map.fetch!(@envelopes, tier)
  end

  @doc """
  Check whether current progress has exceeded the tier envelope.

  Returns `:ok` if within bounds, or `{:exceeded, :files | :cost, details}` if over.
  """
  @spec exceeded?(tier(), %{files: non_neg_integer(), cost: float()}) ::
          :ok | {:exceeded, :files | :cost, map()}
  def exceeded?(tier, %{files: files, cost: cost}) when tier in [:quick, :session, :campaign] do
    envelope = tier_envelope(tier)

    cond do
      files > envelope.max_files ->
        {:exceeded, :files,
         %{current: files, limit: envelope.max_files, overage: files - envelope.max_files}}

      cost > envelope.max_cost ->
        {:exceeded, :cost,
         %{current: cost, limit: envelope.max_cost, overage: cost - envelope.max_cost}}

      true ->
        :ok
    end
  end

  # --- Private ---

  defp classify(signals) do
    cond do
      # Explicit user override takes highest priority
      is_atom(signals[:explicit_scope]) and
          signals[:explicit_scope] in [:quick, :session, :campaign] ->
        signals[:explicit_scope]

      # Plan doc always means campaign
      signals[:plan_doc] == true ->
        :campaign

      # Campaign phrases in description force campaign
      has_campaign_phrase?(signals[:task_description]) ->
        :campaign

      true ->
        tier_from_signals(signals)
    end
  end

  defp tier_from_signals(signals) do
    keyword_tier = keyword_tier(signals[:task_description])
    file_tier = file_count_tier(signals[:file_matches])

    # File count can only escalate, never downgrade the tier
    max_tier(keyword_tier, file_tier)
  end

  defp keyword_tier(nil), do: :session

  defp keyword_tier(description) when is_binary(description) do
    words = description |> String.downcase() |> String.split(~r/[\s\-_\/]+/)

    campaign_hits = Enum.count(words, &(&1 in @campaign_keywords))
    session_hits = Enum.count(words, &(&1 in @session_keywords))
    quick_hits = Enum.count(words, &(&1 in @quick_keywords))

    cond do
      campaign_hits > 0 -> :campaign
      session_hits > quick_hits -> :session
      quick_hits > 0 -> :quick
      true -> :session
    end
  end

  defp file_count_tier(nil), do: :quick
  defp file_count_tier(n) when is_integer(n) and n <= 3, do: :quick
  defp file_count_tier(n) when is_integer(n) and n <= 15, do: :session
  defp file_count_tier(_n), do: :campaign

  defp has_campaign_phrase?(nil), do: false

  defp has_campaign_phrase?(description) when is_binary(description) do
    lower = String.downcase(description)
    Enum.any?(@campaign_phrases, &String.contains?(lower, &1))
  end

  defp estimate_files(signals, tier) do
    case signals[:file_matches] do
      n when is_integer(n) and n > 0 -> n
      _ -> tier_envelope(tier).max_files
    end
  end

  defp max_tier(a, b) do
    tier_rank = %{quick: 0, session: 1, campaign: 2}

    if tier_rank[a] >= tier_rank[b] do
      a
    else
      b
    end
  end
end
