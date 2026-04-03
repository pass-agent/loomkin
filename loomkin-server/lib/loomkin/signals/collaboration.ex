defmodule Loomkin.Signals.Collaboration do
  @moduledoc "Collaboration signals: peer messages, votes, debates, pair mode, conversations."

  defmodule PeerMessage do
    use Jido.Signal,
      type: "collaboration.peer.message",
      schema: [
        from: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule VoteResponse do
    use Jido.Signal,
      type: "collaboration.vote.response",
      schema: [
        vote_id: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule DebateResponse do
    use Jido.Signal,
      type: "collaboration.debate.response",
      schema: [
        debate_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        phase: [type: :atom, required: true]
      ]
  end

  defmodule PairEvent do
    use Jido.Signal,
      type: "collaboration.pair.event",
      schema: [
        team_id: [type: :string, required: true]
      ]
  end

  # --- Conversation signals ---

  defmodule ConversationStarted do
    use Jido.Signal,
      type: "collaboration.conversation.started",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        topic: [type: :string, required: true],
        participants: [type: {:list, :string}, required: true],
        strategy: [type: :string, required: true]
      ]
  end

  defmodule ConversationRoundStarted do
    use Jido.Signal,
      type: "collaboration.conversation.round_started",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        round: [type: :integer, required: true]
      ]
  end

  defmodule ConversationTurn do
    use Jido.Signal,
      type: "collaboration.conversation.turn",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        speaker: [type: :string, required: true],
        content: [type: :string, required: true],
        round: [type: :integer, required: true]
      ]
  end

  defmodule ConversationReaction do
    use Jido.Signal,
      type: "collaboration.conversation.reaction",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        reaction_type: [type: :string, required: true],
        brief: [type: :string, required: true]
      ]
  end

  defmodule ConversationYield do
    use Jido.Signal,
      type: "collaboration.conversation.yield",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        reason: [type: :string, required: false]
      ]
  end

  defmodule ConversationRoundComplete do
    use Jido.Signal,
      type: "collaboration.conversation.round_complete",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        round: [type: :integer, required: true]
      ]
  end

  defmodule ConversationEnded do
    use Jido.Signal,
      type: "collaboration.conversation.ended",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        reason: [type: :string, required: true],
        rounds: [type: :integer, required: true],
        tokens_used: [type: :integer, required: true],
        participants: [type: {:list, :string}, required: false],
        summary: [type: :map, required: false],
        spawned_by: [type: :string, required: false]
      ]
  end

  defmodule ConversationSummarizing do
    use Jido.Signal,
      type: "collaboration.conversation.summarizing",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule ConversationTerminated do
    use Jido.Signal,
      type: "collaboration.conversation.terminated",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        reason: [type: :string, required: true]
      ]
  end

  defmodule ConversationBudgetWarning do
    use Jido.Signal,
      type: "collaboration.conversation.budget_warning",
      schema: [
        conversation_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        tokens_used: [type: :integer, required: true],
        max_tokens: [type: :integer, required: true]
      ]
  end
end
