defmodule Loomkin.Conversations.TurnStrategyTest do
  use ExUnit.Case, async: true

  alias Loomkin.Conversations.TurnStrategy

  @participants [
    %{name: "Alice", persona: %{}, role: :participant},
    %{name: "Bob", persona: %{}, role: :participant},
    %{name: "Carol", persona: %{}, role: :participant}
  ]

  describe "RoundRobin" do
    test "selects first participant when no history" do
      assert TurnStrategy.RoundRobin.next_speaker(@participants, [], 1) == "Alice"
    end

    test "cycles through participants in order" do
      history = [%{speaker: "Alice", content: "hi", round: 1}]
      assert TurnStrategy.RoundRobin.next_speaker(@participants, history, 1) == "Bob"

      history = history ++ [%{speaker: "Bob", content: "hello", round: 1}]
      assert TurnStrategy.RoundRobin.next_speaker(@participants, history, 1) == "Carol"
    end

    test "should_advance_round? returns false until all have spoken" do
      history = [%{speaker: "Alice", content: "hi", round: 1}]
      refute TurnStrategy.RoundRobin.should_advance_round?(@participants, history, 1)

      history = history ++ [%{speaker: "Bob", content: "hey", round: 1}]
      refute TurnStrategy.RoundRobin.should_advance_round?(@participants, history, 1)
    end

    test "should_advance_round? returns true when all have spoken" do
      history = [
        %{speaker: "Alice", content: "hi", round: 1},
        %{speaker: "Bob", content: "hey", round: 1},
        %{speaker: "Carol", content: "hello", round: 1}
      ]

      assert TurnStrategy.RoundRobin.should_advance_round?(@participants, history, 1)
    end

    test "new round starts fresh cycle" do
      history = [
        %{speaker: "Alice", content: "hi", round: 1},
        %{speaker: "Bob", content: "hey", round: 1},
        %{speaker: "Carol", content: "hello", round: 1}
      ]

      assert TurnStrategy.RoundRobin.next_speaker(@participants, history, 2) == "Alice"
    end
  end

  describe "Weighted" do
    test "prioritizes participants who spoke least" do
      history = [
        %{speaker: "Alice", content: "hi", round: 1},
        %{speaker: "Alice", content: "more", round: 1},
        %{speaker: "Bob", content: "hey", round: 1}
      ]

      # Carol hasn't spoken at all, should be prioritized
      assert TurnStrategy.Weighted.next_speaker(@participants, history, 2) == "Carol"
    end

    test "selects first participant when no history" do
      # With no history, all have count 0 — min_by returns first
      result = TurnStrategy.Weighted.next_speaker(@participants, [], 1)
      assert result == "Alice"
    end

    test "should_advance_round? works like round_robin" do
      history = [
        %{speaker: "Alice", content: "hi", round: 1},
        %{speaker: "Bob", content: "hey", round: 1},
        %{speaker: "Carol", content: "hello", round: 1}
      ]

      assert TurnStrategy.Weighted.should_advance_round?(@participants, history, 1)
    end
  end

  describe "Facilitator" do
    @facilitator_participants [
      %{name: "Moderator", persona: %{}, role: :facilitator},
      %{name: "Expert", persona: %{}, role: :participant},
      %{name: "Critic", persona: %{}, role: :participant}
    ]

    test "facilitator speaks first in each round" do
      assert TurnStrategy.Facilitator.next_speaker(@facilitator_participants, [], 1) ==
               "Moderator"
    end

    test "non-facilitators speak after facilitator" do
      history = [%{speaker: "Moderator", content: "let's begin", round: 1}]

      assert TurnStrategy.Facilitator.next_speaker(@facilitator_participants, history, 1) ==
               "Expert"
    end

    test "should_advance_round? requires all participants" do
      history = [
        %{speaker: "Moderator", content: "begin", round: 1},
        %{speaker: "Expert", content: "agreed", round: 1}
      ]

      refute TurnStrategy.Facilitator.should_advance_round?(
               @facilitator_participants,
               history,
               1
             )

      history = history ++ [%{speaker: "Critic", content: "disagree", round: 1}]

      assert TurnStrategy.Facilitator.should_advance_round?(
               @facilitator_participants,
               history,
               1
             )
    end
  end

  describe "module_for/1" do
    test "returns correct modules" do
      assert TurnStrategy.module_for(:round_robin) == TurnStrategy.RoundRobin
      assert TurnStrategy.module_for(:weighted) == TurnStrategy.Weighted
      assert TurnStrategy.module_for(:facilitator) == TurnStrategy.Facilitator
    end
  end
end
