defmodule Loomkin.Conversations.WeaverTest do
  use ExUnit.Case, async: false

  alias Loomkin.Conversations.Server
  alias Loomkin.Conversations.Weaver

  @participants [
    %{name: "Alice", persona: %{}, role: :participant},
    %{name: "Bob", persona: %{}, role: :participant}
  ]

  @history [
    %{
      speaker: "Alice",
      content: "I think we should use GenServer",
      round: 1,
      type: :speech,
      timestamp: DateTime.utc_now()
    },
    %{
      speaker: "Bob",
      content: "I agree, but with ETS backing",
      round: 1,
      type: :speech,
      timestamp: DateTime.utc_now()
    },
    %{
      speaker: "Alice",
      content: "Good point about ETS",
      round: 2,
      type: :speech,
      timestamp: DateTime.utc_now()
    },
    %{
      speaker: "Bob",
      content: "Let's go with that approach",
      round: 2,
      type: :speech,
      timestamp: DateTime.utc_now()
    }
  ]

  setup do
    conv_id = Ecto.UUID.generate()
    team_id = Ecto.UUID.generate()

    %{conv_id: conv_id, team_id: team_id}
  end

  describe "start_link/1" do
    test "starts weaver and subscribes to conversation topic", ctx do
      pid =
        start_supervised!(
          {Weaver,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           model: "anthropic:claude-haiku-4-5-20251001"}
        )

      assert Process.alive?(pid)
    end
  end

  describe "summarization" do
    test "generates fallback summary when llm unavailable and attaches to server", ctx do
      # Start the conversation server (temporary so it won't restart after :stop)
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Cache architecture",
         participants: @participants,
         max_rounds: 5},
        id: :summary_server,
        restart: :temporary
      )

      # Subscribe to the Jido Signal Bus for conversation ended signals
      {:ok, _sub_id} = Loomkin.Signals.subscribe("collaboration.conversation.ended")

      # Start the weaver
      weaver_pid =
        start_supervised!(
          {Weaver,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           model: "anthropic:claude-haiku-4-5-20251001",
           spawned_by: "task-agent"},
          id: :summary_weaver
        )

      ref = Process.monitor(weaver_pid)

      # Simulate the summarize message (what ConversationServer sends)
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:summarize, ctx.conv_id, @history, "Cache architecture", @participants}
      )

      # Weaver should stop after summarizing
      assert_receive {:DOWN, ^ref, :process, ^weaver_pid, :normal}, 5_000

      # Summary should be delivered via the ConversationEnded signal (emitted by Server.attach_summary)
      assert_receive {:signal, %Jido.Signal{type: "collaboration.conversation.ended"} = sig},
                     5_000

      assert sig.data.conversation_id == ctx.conv_id
      summary = sig.data.summary

      # Verify summary structure
      assert summary.topic == "Cache architecture"
      assert summary.participants == ["Alice", "Bob"]
      assert is_list(summary.key_points)
      assert is_list(summary.consensus)
      assert is_list(summary.disagreements)
      assert is_list(summary.open_questions)
      assert is_list(summary.recommended_actions)

      # Server stops after attach_summary — wait for process exit and Registry cleanup
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Registry.lookup(Loomkin.Conversations.Registry, ctx.conv_id) do
          [] ->
            {:halt, :ok}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

      assert Registry.lookup(Loomkin.Conversations.Registry, ctx.conv_id) == []
    end

    test "weaver ignores your_turn messages", ctx do
      pid =
        start_supervised!(
          {Weaver,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           model: "anthropic:claude-haiku-4-5-20251001"},
          id: :ignore_turn_weaver
        )

      # Send a turn notification — should be ignored
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:your_turn, ctx.conv_id, [], "topic", nil, "Weaver"}
      )

      # Synchronize via :sys.get_state instead of sleeping
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "weaver ignores summarize for different conversation", ctx do
      pid =
        start_supervised!(
          {Weaver,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           model: "anthropic:claude-haiku-4-5-20251001"},
          id: :diff_conv_weaver
        )

      # Send summarize for a different conversation
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:summarize, "different-id", @history, "Other topic", @participants}
      )

      # Synchronize via :sys.get_state instead of sleeping
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end
end
