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
      {:ok, pid} =
        Agent.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          persona: @persona,
          model: "anthropic:claude-haiku-4-5-20251001",
          topic: "Test topic"
        )

      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
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
      {:ok, agent_pid} =
        Agent.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          persona: @persona,
          model: "anthropic:claude-haiku-4-5-20251001",
          topic: "Test topic"
        )

      # Now start the server — its :your_turn broadcast will reach the agent
      {:ok, _server} =
        start_supervised(
          {Server,
           id: ctx.conv_id,
           team_id: ctx.team_id,
           topic: "Test topic",
           participants: @participants,
           max_rounds: 3}
        )

      assert Process.alive?(agent_pid)

      # Wait for the agent to process the turn and yield.
      # Poll until history is non-empty (up to 3 seconds).
      state =
        Enum.reduce_while(1..30, nil, fn _, _ ->
          Process.sleep(100)
          {:ok, st} = Server.get_state(ctx.conv_id)

          if length(st.history) > 0 do
            {:halt, st}
          else
            {:cont, nil}
          end
        end)

      assert state != nil, "Agent should have yielded after LLM error"
      entry = hd(state.history)
      assert entry.speaker == "Expert"
      assert entry.type == :yield

      GenServer.stop(agent_pid, :normal, 5_000)
    end

    test "agent stops on summarize message", ctx do
      {:ok, pid} =
        Agent.start_link(
          conversation_id: ctx.conv_id,
          team_id: ctx.team_id,
          persona: @persona,
          model: "anthropic:claude-haiku-4-5-20251001",
          topic: "Test topic"
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
