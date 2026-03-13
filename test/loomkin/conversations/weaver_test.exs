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

    on_exit(fn ->
      case Registry.lookup(Loomkin.Conversations.Registry, conv_id) do
        [{pid, _}] ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)

        [] ->
          :ok
      end
    end)

    %{conv_id: conv_id, team_id: team_id}
  end

  describe "start_link/1" do
    test "starts weaver and subscribes to conversation topic", ctx do
      {:ok, pid} =
        Weaver.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          model: "anthropic:claude-haiku-4-5-20251001"
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "summarization" do
    test "generates fallback summary when llm unavailable and attaches to server", ctx do
      # Start the conversation server
      {:ok, _server} =
        start_supervised(
          {Server,
           id: ctx.conv_id,
           team_id: ctx.team_id,
           topic: "Cache architecture",
           participants: @participants,
           max_rounds: 5}
        )

      # Subscribe to summary notifications
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{ctx.conv_id}:summary")

      # Start the weaver
      {:ok, weaver_pid} =
        Weaver.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          model: "anthropic:claude-haiku-4-5-20251001",
          spawned_by: "task-agent"
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

      # Summary should be delivered via PubSub
      assert_receive {:conversation_summary, conv_id, summary}, 5_000
      assert conv_id == ctx.conv_id

      # Verify summary structure
      assert summary.topic == "Cache architecture"
      assert summary.participants == ["Alice", "Bob"]
      assert is_list(summary.key_points)
      assert is_list(summary.consensus)
      assert is_list(summary.disagreements)
      assert is_list(summary.open_questions)
      assert is_list(summary.recommended_actions)

      # Server should have the summary attached
      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :completed
      assert state.summary != nil
    end

    test "weaver ignores your_turn messages", ctx do
      {:ok, pid} =
        Weaver.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          model: "anthropic:claude-haiku-4-5-20251001"
        )

      # Send a turn notification — should be ignored
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:your_turn, ctx.conv_id, [], "topic", nil, "Weaver"}
      )

      Process.sleep(100)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "weaver ignores summarize for different conversation", ctx do
      {:ok, pid} =
        Weaver.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          model: "anthropic:claude-haiku-4-5-20251001"
        )

      # Send summarize for a different conversation
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:summarize, "different-id", @history, "Other topic", @participants}
      )

      Process.sleep(100)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
