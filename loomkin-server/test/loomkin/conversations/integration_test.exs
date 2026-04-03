defmodule Loomkin.Conversations.IntegrationTest do
  @moduledoc """
  Integration tests for the conversation system end-to-end.
  Tests the full lifecycle: server + agents + weaver with mocked LLM.
  """

  use ExUnit.Case, async: false

  alias Loomkin.Conversations.Server
  alias Loomkin.Conversations.Weaver

  @participants [
    %{name: "Alice", persona: %{}, role: :participant},
    %{name: "Bob", persona: %{}, role: :participant},
    %{name: "Carol", persona: %{}, role: :participant}
  ]

  setup do
    conv_id = Ecto.UUID.generate()
    team_id = Ecto.UUID.generate()

    # Subscribe before server starts so we don't miss the first turn notification
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{conv_id}")

    %{conv_id: conv_id, team_id: team_id}
  end

  describe "3-agent conversation lifecycle" do
    test "manual simulation with weaver produces summary", ctx do
      # Subscribe to collaboration signals to receive the ended signal with summary
      Loomkin.Signals.subscribe("collaboration.**")

      # Start conversation server with max 1 round (temporary so it won't restart after :stop)
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Architecture decision",
         participants: @participants,
         max_rounds: 1},
        id: :lifecycle_server,
        restart: :temporary
      )

      # Start the weaver
      weaver_pid =
        start_supervised!(
          {Weaver,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           model: "anthropic:claude-haiku-4-5-20251001",
           spawned_by: "task-agent"},
          id: :lifecycle_weaver
        )

      weaver_ref = Process.monitor(weaver_pid)

      # Begin the conversation now that weaver is subscribed
      :ok = Server.begin(ctx.conv_id)

      # Simulate 3 agents speaking (rather than relying on LLM calls)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000
      Server.speak(ctx.conv_id, "Alice", "I think we should use GenServer")

      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "Agreed, with ETS backing for persistence")

      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "We need to consider failure modes")

      # Round 1 complete, max_rounds=1, so conversation should end
      # Weaver should receive summarize and stop
      assert_receive {:DOWN, ^weaver_ref, :process, ^weaver_pid, :normal}, 10_000

      # Summary should arrive via Jido signal (ConversationEnded)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.conversation.ended",
                        data: %{
                          conversation_id: conv_id,
                          summary: summary
                        }
                      }},
                     5_000

      assert conv_id == ctx.conv_id

      # Verify summary structure (fallback summary since no real LLM)
      assert summary.topic == "Architecture decision"
      assert summary.participants == ["Alice", "Bob", "Carol"]
      assert is_list(summary.key_points)
      assert is_list(summary.consensus)
      assert is_list(summary.disagreements)
      assert is_list(summary.open_questions)
      assert is_list(summary.recommended_actions)

      # Server stops after summary is attached — verify it's no longer active
      assert {:error, :conversation_not_found} = Server.get_state(ctx.conv_id)
    end

    test "force terminate ends conversation and triggers summarization", ctx do
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Force terminate test",
         participants: @participants,
         max_rounds: 10},
        id: :force_term_server
      )

      :ok = Server.begin(ctx.conv_id)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      # Have one agent speak
      Server.speak(ctx.conv_id, "Alice", "Something important")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000

      # Force terminate mid-conversation
      assert :ok = Server.terminate_conversation(ctx.conv_id, :cancelled)

      # Should receive summarize notification
      assert_receive {:summarize, _, _, _, _}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
      assert length(state.history) == 1
    end
  end

  describe "concurrent conversations" do
    test "two simultaneous conversations don't interfere", ctx do
      conv_id_2 = Ecto.UUID.generate()
      team_id_2 = Ecto.UUID.generate()

      # Subscribe to conversation 2 before starting it
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{conv_id_2}")

      participants_2 = [
        %{name: "Dave", persona: %{}, role: :participant},
        %{name: "Eve", persona: %{}, role: :participant}
      ]

      # Start two conversations
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Topic A",
         participants: @participants,
         max_rounds: 2},
        id: :conv_1
      )

      start_supervised!(
        {Server,
         id: conv_id_2,
         team_id: team_id_2,
         topic: "Topic B",
         participants: participants_2,
         max_rounds: 2},
        id: :conv_2
      )

      # Begin both conversations
      :ok = Server.begin(ctx.conv_id)
      :ok = Server.begin(conv_id_2)

      # Verify both are independently active
      {:ok, ctx_1} = Server.get_context(ctx.conv_id)
      {:ok, ctx_2} = Server.get_context(conv_id_2)

      assert ctx_1.topic == "Topic A"
      assert ctx_2.topic == "Topic B"
      assert ctx_1.participants == ["Alice", "Bob", "Carol"]
      assert ctx_2.participants == ["Dave", "Eve"]

      # Speak in conversation 1
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000
      assert :ok = Server.speak(ctx.conv_id, "Alice", "Hello from Topic A")

      # Speak in conversation 2
      assert_receive {:your_turn, _, _, _, _, "Dave"}, 1_000
      assert :ok = Server.speak(conv_id_2, "Dave", "Hello from Topic B")

      # Verify histories are separate
      {:ok, state_1} = Server.get_state(ctx.conv_id)
      {:ok, state_2} = Server.get_state(conv_id_2)

      assert length(state_1.history) == 1
      assert hd(state_1.history).content == "Hello from Topic A"

      assert length(state_2.history) == 1
      assert hd(state_2.history).content == "Hello from Topic B"
    end
  end

  describe "budget tracking" do
    test "token usage accumulates correctly across agents", ctx do
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Budget test",
         participants: @participants,
         max_rounds: 5,
         max_tokens: 1000},
        id: :budget_server
      )

      :ok = Server.begin(ctx.conv_id)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      # Each speak call with explicit token counts
      Server.speak(ctx.conv_id, "Alice", "First message", tokens: 100)
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000

      Server.speak(ctx.conv_id, "Bob", "Second message", tokens: 200)
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000

      Server.speak(ctx.conv_id, "Carol", "Third message", tokens: 150)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.tokens_used == 450
      assert state.status == :active

      # Push over budget
      Server.speak(ctx.conv_id, "Alice", "Over budget", tokens: 600)

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.tokens_used == 1050
      assert state.status == :summarizing
    end

    test "token estimation works for content without explicit tokens", ctx do
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Estimation test",
         participants: @participants,
         max_rounds: 5},
        id: :estimation_server
      )

      :ok = Server.begin(ctx.conv_id)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      # 12-char message ~= 4 tokens (12/4 + 1 = 4)
      Server.speak(ctx.conv_id, "Alice", "Hello world!")

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.tokens_used == 4
    end
  end
end
