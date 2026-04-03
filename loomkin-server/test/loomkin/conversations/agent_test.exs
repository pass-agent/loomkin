defmodule Loomkin.Conversations.AgentTest do
  use ExUnit.Case, async: false

  alias Loomkin.Conversations.Agent
  alias Loomkin.Conversations.Persona
  alias Loomkin.Conversations.Server

  @persona %Persona{
    name: "Expert",
    description: "a domain expert",
    perspective: "Technical perspective",
    personality: "Direct and analytical",
    expertise: "Software architecture",
    goal: "Provide technical insight"
  }

  @participants [
    %{name: "Expert", persona: %{}, role: :participant},
    %{name: "Critic", persona: %{}, role: :participant}
  ]

  setup do
    conv_id = Ecto.UUID.generate()
    team_id = Ecto.UUID.generate()

    %{conv_id: conv_id, team_id: team_id}
  end

  describe "Persona.system_prompt/2" do
    test "interpolates all persona fields" do
      prompt = Persona.system_prompt(@persona, "Test topic")

      assert prompt =~ "You are Expert"
      assert prompt =~ "a domain expert"
      assert prompt =~ "Technical perspective"
      assert prompt =~ "Direct and analytical"
      assert prompt =~ "Software architecture"
      assert prompt =~ "Provide technical insight"
      assert prompt =~ "Test topic"
      assert prompt =~ "Stay in character"
    end

    test "handles nil persona fields gracefully" do
      persona = %Persona{name: "Simple"}
      prompt = Persona.system_prompt(persona, "Topic")

      assert prompt =~ "You are Simple"
      assert prompt =~ "No specific perspective provided."
    end

    test "includes context when provided" do
      prompt = Persona.system_prompt(@persona, "Test topic", "Some background context")

      assert prompt =~ "Background Context"
      assert prompt =~ "Some background context"
    end
  end

  describe "Persona.from_map/1" do
    test "creates persona from atom-keyed map" do
      persona = Persona.from_map(%{name: "Alice", expertise: "Elixir"})
      assert persona.name == "Alice"
      assert persona.expertise == "Elixir"
    end

    test "creates persona from string-keyed map" do
      persona = Persona.from_map(%{"name" => "Bob", "goal" => "Win"})
      assert persona.name == "Bob"
      assert persona.goal == "Win"
    end
  end

  describe "start_link/1" do
    test "starts agent and subscribes to conversation topic", ctx do
      pid =
        start_supervised!(
          {Agent,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           persona: @persona,
           model: "anthropic:claude-haiku-4-5-20251001",
           topic: "Test topic"}
        )

      assert Process.alive?(pid)
    end
  end

  describe "conversation_tools/0" do
    test "returns the conversation tool modules" do
      tools = Agent.conversation_tools()
      assert length(tools) == 4

      tool_names = Enum.map(tools, fn mod -> mod.__action_metadata__().name end)

      assert "speak" in tool_names
      assert "react" in tool_names
      assert "yield" in tool_names
      assert "end_conversation" in tool_names
    end
  end

  describe "turn handling" do
    test "agent receives turn notification and yields on llm error", ctx do
      # Start agent first so it's subscribed before the server emits :your_turn
      agent_pid =
        start_supervised!(
          {Agent,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           persona: @persona,
           model: "anthropic:claude-haiku-4-5-20251001",
           topic: "Test topic"},
          id: :test_agent
        )

      # Now start the server and begin — :your_turn broadcast will reach the agent
      start_supervised!(
        {Server,
         id: ctx.conv_id,
         team_id: ctx.team_id,
         topic: "Test topic",
         participants: @participants,
         max_rounds: 3},
        id: :test_server
      )

      :ok = Server.begin(ctx.conv_id)

      assert Process.alive?(agent_pid)

      # Wait for the agent to process the turn and yield.
      # Poll via synchronous get_state (avoids Process.sleep).
      state =
        Enum.reduce_while(1..30, nil, fn _, _ ->
          # Use :sys.get_state to synchronize with the agent's mailbox
          _ = :sys.get_state(agent_pid)
          {:ok, st} = Server.get_state(ctx.conv_id)

          if length(st.history) > 0 do
            {:halt, st}
          else
            # Brief pause to let the async Task complete
            Process.sleep(100)
            {:cont, nil}
          end
        end)

      assert state != nil, "Agent should have yielded after LLM error"
      # History is stored in reverse, most recent first
      entry = hd(state.history)
      assert entry.speaker == "Expert"
      assert entry.type == :yield
    end

    test "agent stops on summarize message", ctx do
      pid =
        start_supervised!(
          {Agent,
           conversation_id: ctx.conv_id,
           team_id: ctx.team_id,
           persona: @persona,
           model: "anthropic:claude-haiku-4-5-20251001",
           topic: "Test topic"},
          id: :summarize_agent
        )

      ref = Process.monitor(pid)

      # Simulate the summarize message
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{ctx.conv_id}",
        {:summarize, ctx.conv_id, [], "Test topic", []}
      )

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end
end
