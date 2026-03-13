defmodule Loomkin.Conversations.TurnStrategy do
  @moduledoc "Behaviour and implementations for conversation turn ordering."

  @type participant :: %{name: String.t(), persona: map(), role: atom()}
  @type entry :: %{speaker: String.t(), content: String.t(), round: non_neg_integer()}

  @callback next_speaker([participant()], [entry()], non_neg_integer()) :: String.t()
  @callback should_advance_round?([participant()], [entry()], non_neg_integer()) :: boolean()

  # -------------------------------------------------------------------
  # Round-robin: fixed order, each participant speaks once per round
  # -------------------------------------------------------------------

  defmodule RoundRobin do
    @moduledoc false
    @behaviour Loomkin.Conversations.TurnStrategy

    @impl true
    def next_speaker(participants, history, current_round) do
      names = Enum.map(participants, & &1.name)

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      Enum.find(names, List.first(names), fn name ->
        name not in speakers_this_round
      end)
    end

    @impl true
    def should_advance_round?(participants, history, current_round) do
      names = participants |> Enum.map(& &1.name) |> MapSet.new()

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      MapSet.subset?(names, speakers_this_round)
    end
  end

  # -------------------------------------------------------------------
  # Weighted: prioritizes participants who have spoken least recently
  # -------------------------------------------------------------------

  defmodule Weighted do
    @moduledoc false
    @behaviour Loomkin.Conversations.TurnStrategy

    @impl true
    def next_speaker(participants, history, current_round) do
      names = Enum.map(participants, & &1.name)

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      remaining = Enum.reject(names, &(&1 in speakers_this_round))

      if remaining == [] do
        List.first(names)
      else
        # Pick the participant who spoke least overall
        counts =
          Enum.frequencies_by(history, & &1.speaker)

        Enum.min_by(remaining, fn name -> Map.get(counts, name, 0) end)
      end
    end

    @impl true
    def should_advance_round?(participants, history, current_round) do
      names = participants |> Enum.map(& &1.name) |> MapSet.new()

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      MapSet.subset?(names, speakers_this_round)
    end
  end

  # -------------------------------------------------------------------
  # Facilitator: designated facilitator controls who speaks next
  # -------------------------------------------------------------------

  defmodule Facilitator do
    @moduledoc false
    @behaviour Loomkin.Conversations.TurnStrategy

    @impl true
    def next_speaker(participants, history, current_round) do
      facilitator = Enum.find(participants, fn p -> p.role == :facilitator end)

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      non_facilitator_names =
        participants
        |> Enum.reject(&(&1.role == :facilitator))
        |> Enum.map(& &1.name)

      remaining_non_fac = Enum.reject(non_facilitator_names, &(&1 in speakers_this_round))

      cond do
        # Facilitator hasn't spoken yet this round — they go first
        facilitator && facilitator.name not in speakers_this_round ->
          facilitator.name

        # Non-facilitators still need to speak
        remaining_non_fac != [] ->
          List.first(remaining_non_fac)

        # Everyone has spoken
        true ->
          (facilitator && facilitator.name) || List.first(Enum.map(participants, & &1.name))
      end
    end

    @impl true
    def should_advance_round?(participants, history, current_round) do
      names = participants |> Enum.map(& &1.name) |> MapSet.new()

      speakers_this_round =
        history
        |> Enum.filter(&(&1.round == current_round))
        |> Enum.map(& &1.speaker)
        |> MapSet.new()

      MapSet.subset?(names, speakers_this_round)
    end
  end

  # -------------------------------------------------------------------
  # Dispatcher: resolves strategy atom to implementation module
  # -------------------------------------------------------------------

  @doc "Returns the strategy module for the given atom."
  def module_for(:round_robin), do: RoundRobin
  def module_for(:weighted), do: Weighted
  def module_for(:facilitator), do: Facilitator
end
