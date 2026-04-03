defmodule Loomkin.Conversations.TurnStrategy do
  @moduledoc "Behaviour and shared logic for conversation turn ordering."

  alias __MODULE__.Facilitator
  alias __MODULE__.RoundRobin
  alias __MODULE__.Weighted

  @type participant :: %{name: String.t(), persona: map(), role: atom()}
  @type entry :: %{speaker: String.t(), content: String.t(), round: non_neg_integer()}

  @callback next_speaker([participant()], [entry()], non_neg_integer()) :: String.t()
  @callback should_advance_round?([participant()], [entry()], non_neg_integer()) :: boolean()

  @doc """
  Shared implementation of should_advance_round? — checks whether all participants
  have taken their turn (speech or yield) in the current round.
  Reactions do not count as taking a turn.
  """
  def should_advance_round?(participants, history, current_round) do
    names = participants |> Enum.map(& &1.name) |> MapSet.new()
    MapSet.subset?(names, speakers_this_round(history, current_round))
  end

  @doc "Returns the set of participants who have taken a turn (speech or yield) in a round."
  def speakers_this_round(history, current_round) do
    history
    |> Enum.filter(&(&1.round == current_round and turn_entry?(&1.type)))
    |> Enum.map(& &1.speaker)
    |> MapSet.new()
  end

  defp turn_entry?(:speech), do: true
  defp turn_entry?(:yield), do: true
  defp turn_entry?(_), do: false

  @doc "Returns the strategy module for the given atom."
  def module_for(:round_robin), do: RoundRobin
  def module_for(:weighted), do: Weighted
  def module_for(:facilitator), do: Facilitator

  def module_for(unknown) do
    raise ArgumentError, "Unknown turn strategy: #{inspect(unknown)}"
  end
end
