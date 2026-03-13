defmodule Loomkin.Conversations.TurnStrategy.Facilitator do
  @moduledoc "Facilitator: designated facilitator controls who speaks next."

  @behaviour Loomkin.Conversations.TurnStrategy

  @impl true
  def next_speaker(participants, history, current_round) do
    spoken = Loomkin.Conversations.TurnStrategy.speakers_this_round(history, current_round)

    case Enum.find(participants, fn p -> p.role == :facilitator end) do
      nil ->
        names = Enum.map(participants, & &1.name)
        Enum.find(names, List.first(names), fn name -> name not in spoken end)

      facilitator ->
        non_facilitator_names =
          participants
          |> Enum.reject(&(&1.role == :facilitator))
          |> Enum.map(& &1.name)

        remaining_non_fac = Enum.reject(non_facilitator_names, &(&1 in spoken))

        cond do
          facilitator.name not in spoken -> facilitator.name
          remaining_non_fac != [] -> List.first(remaining_non_fac)
          true -> facilitator.name
        end
    end
  end

  @impl true
  defdelegate should_advance_round?(participants, history, current_round),
    to: Loomkin.Conversations.TurnStrategy
end
