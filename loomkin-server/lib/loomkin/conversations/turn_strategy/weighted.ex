defmodule Loomkin.Conversations.TurnStrategy.Weighted do
  @moduledoc "Weighted: prioritizes participants who have spoken least recently."

  @behaviour Loomkin.Conversations.TurnStrategy

  @impl true
  def next_speaker(participants, history, current_round) do
    names = Enum.map(participants, & &1.name)
    spoken = Loomkin.Conversations.TurnStrategy.speakers_this_round(history, current_round)

    remaining = Enum.reject(names, &(&1 in spoken))

    if remaining == [] do
      List.first(names)
    else
      counts = Enum.frequencies_by(history, & &1.speaker)
      Enum.min_by(remaining, fn name -> Map.get(counts, name, 0) end)
    end
  end

  @impl true
  defdelegate should_advance_round?(participants, history, current_round),
    to: Loomkin.Conversations.TurnStrategy
end
