defmodule Loomkin.Conversations.TurnStrategy.RoundRobin do
  @moduledoc "Round-robin: fixed order, each participant speaks once per round."

  @behaviour Loomkin.Conversations.TurnStrategy

  @impl true
  def next_speaker(participants, history, current_round) do
    names = Enum.map(participants, & &1.name)
    spoken = Loomkin.Conversations.TurnStrategy.speakers_this_round(history, current_round)

    Enum.find(names, List.first(names), fn name ->
      name not in spoken
    end)
  end

  @impl true
  defdelegate should_advance_round?(participants, history, current_round),
    to: Loomkin.Conversations.TurnStrategy
end
