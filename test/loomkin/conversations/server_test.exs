defmodule Loomkin.Conversations.ServerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Conversations.Server

  @participants [
    %{name: "Alice", persona: %{}, role: :participant},
    %{name: "Bob", persona: %{}, role: :participant},
    %{name: "Carol", persona: %{}, role: :participant}
  ]

  setup do
    conv_id = Ecto.UUID.generate()
    team_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{conv_id}")

    %{conv_id: conv_id, team_id: team_id}
  end

  defp start_server(ctx, opts \\ []) do
    defaults = [
      id: ctx.conv_id,
      team_id: ctx.team_id,
      topic: "Test topic",
      participants: @participants,
      turn_strategy: :round_robin,
      max_rounds: 5
    ]

    {:ok, pid} = start_supervised({Server, Keyword.merge(defaults, opts)})
    pid
  end

  describe "start_link/1" do
    test "starts and emits first turn notification", ctx do
      start_server(ctx)

      assert_receive {:your_turn, conv_id, [], "Test topic", _, "Alice"}, 1_000
      assert conv_id == ctx.conv_id
    end

    test "uses round_robin strategy by default", ctx do
      start_server(ctx)
      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.turn_strategy == :round_robin
    end
  end

  describe "speak/3" do
    test "appends to history and advances turn", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      assert :ok = Server.speak(ctx.conv_id, "Alice", "Hello everyone!")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert length(state.history) == 1
      # History is stored in reverse order (most recent first)
      assert hd(state.history).speaker == "Alice"
      assert hd(state.history).content == "Hello everyone!"
    end

    test "tracks token usage", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "Hello world", tokens: 10)

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.tokens_used == 10
    end

    test "returns error when conversation is not active", ctx do
      start_server(ctx, max_rounds: 1)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "hi")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "hey")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "hello")

      assert {:error, :conversation_not_active} =
               Server.speak(ctx.conv_id, "Alice", "more stuff")
    end
  end

  describe "yield/2" do
    test "records yield and advances turn", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      assert :ok = Server.yield(ctx.conv_id, "Alice", "nothing to add")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert length(state.history) == 1
      assert hd(state.history).type == :yield
    end

    test "returns error when conversation is not active", ctx do
      start_server(ctx, max_rounds: 1)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "hi")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "hey")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "hello")

      assert {:error, :conversation_not_active} =
               Server.yield(ctx.conv_id, "Alice")
    end

    test "all yields in a round terminates conversation", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.yield(ctx.conv_id, "Alice")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.yield(ctx.conv_id, "Bob")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.yield(ctx.conv_id, "Carol")

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
    end
  end

  describe "react/4" do
    test "appends reaction without advancing turn order", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      assert :ok = Server.react(ctx.conv_id, "Bob", :agree, "Good point!")

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert length(state.history) == 1
      assert hd(state.history).type == {:reaction, :agree}
      assert state.current_speaker == "Alice"
    end

    test "returns error when conversation is not active", ctx do
      start_server(ctx, max_rounds: 1)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "hi")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "hey")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "hello")

      assert {:error, :conversation_not_active} =
               Server.react(ctx.conv_id, "Alice", :agree, "late reaction")
    end
  end

  describe "get_context/1" do
    test "returns conversation context with chronological history", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "first")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000

      Server.speak(ctx.conv_id, "Bob", "second")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000

      {:ok, context} = Server.get_context(ctx.conv_id)
      assert context.topic == "Test topic"
      assert context.current_round == 1
      assert context.participants == ["Alice", "Bob", "Carol"]
      assert context.status == :active

      # get_context returns chronological order
      assert hd(context.history).speaker == "Alice"
      assert List.last(context.history).speaker == "Bob"
    end
  end

  describe "termination conditions" do
    test "max rounds triggers termination", ctx do
      start_server(ctx, max_rounds: 1)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "round 1")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "round 1")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "round 1")

      # Should receive summarize notification
      assert_receive {:summarize, _, _, _, _}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
    end

    test "max tokens triggers termination", ctx do
      start_server(ctx, max_tokens: 20)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "short", tokens: 15)
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "over budget", tokens: 10)

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
    end

    test "force terminate ends conversation", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      assert :ok = Server.terminate_conversation(ctx.conv_id, :cancelled)

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
    end

    test "inactivity timeout ends conversation", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      [{pid, _}] = Registry.lookup(Loomkin.Conversations.Registry, ctx.conv_id)
      send(pid, :inactivity_timeout)

      # Synchronize by calling get_state (which forces the GenServer to process all prior messages)
      _ = Server.get_state(ctx.conv_id)

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.status == :summarizing
    end
  end

  describe "attach_summary/2" do
    test "attaches summary, completes, and stops server", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.terminate_conversation(ctx.conv_id, :test)

      summary = %{
        topic: "Test topic",
        key_points: ["Point 1"],
        consensus: [],
        disagreements: []
      }

      assert :ok = Server.attach_summary(ctx.conv_id, summary)

      # Server stops after attach_summary
      assert {:error, :conversation_not_found} = Server.get_state(ctx.conv_id)
    end
  end

  describe "round advancement" do
    test "advances round after all participants speak", ctx do
      start_server(ctx)
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      Server.speak(ctx.conv_id, "Alice", "round 1")
      assert_receive {:your_turn, _, _, _, _, "Bob"}, 1_000
      Server.speak(ctx.conv_id, "Bob", "round 1")
      assert_receive {:your_turn, _, _, _, _, "Carol"}, 1_000
      Server.speak(ctx.conv_id, "Carol", "round 1")

      # Should be in round 2 now
      assert_receive {:your_turn, _, _, _, _, "Alice"}, 1_000

      {:ok, state} = Server.get_state(ctx.conv_id)
      assert state.current_round == 2
    end
  end

  describe "error handling" do
    test "returns error for nonexistent conversation" do
      assert {:error, :conversation_not_found} =
               Server.speak("nonexistent", "Alice", "hello")
    end
  end
end
