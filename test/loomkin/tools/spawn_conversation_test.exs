defmodule Loomkin.Tools.SpawnConversationTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.SpawnConversation

  @valid_personas [
    %{name: "Alice", perspective: "Optimistic", expertise: "Design"},
    %{name: "Bob", perspective: "Skeptical", expertise: "Engineering"}
  ]

  @valid_context %{
    team_id: "test-team",
    session_id: "test-session",
    agent_name: "test-agent",
    model: nil
  }

  describe "persona validation" do
    test "rejects fewer than 2 personas" do
      params = %{
        topic: "Test topic",
        personas: [%{name: "Solo", perspective: "Alone", expertise: "Everything"}]
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "At least 2"
    end

    test "rejects more than 6 personas" do
      personas =
        for i <- 1..7 do
          %{name: "Agent #{i}", perspective: "View #{i}", expertise: "Skill #{i}"}
        end

      params = %{topic: "Test topic", personas: personas}
      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "At most 6"
    end

    test "rejects personas missing required fields" do
      params = %{
        topic: "Test topic",
        personas: [
          %{name: "Alice", perspective: "Optimistic"},
          %{name: "Bob", perspective: "Skeptical", expertise: "Engineering"}
        ]
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "missing expertise"
    end

    test "rejects personas with empty required fields" do
      params = %{
        topic: "Test topic",
        personas: [
          %{name: "Alice", perspective: "", expertise: "Design"},
          %{name: "Bob", perspective: "Skeptical", expertise: "Engineering"}
        ]
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "missing perspective"
    end

    test "accepts string-keyed persona maps" do
      params = %{
        topic: "Test topic",
        personas: [
          %{"name" => "Alice", "perspective" => "Optimistic", "expertise" => "Design"},
          %{"name" => "Bob", "perspective" => "Skeptical", "expertise" => "Engineering"}
        ]
      }

      result = SpawnConversation.run(params, @valid_context)
      assert {:ok, %{conversation_id: _, result: _}} = result
    end
  end

  describe "strategy validation" do
    test "facilitator strategy requires facilitator param" do
      params = %{
        topic: "Test topic",
        personas: @valid_personas,
        strategy: "facilitator"
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "requires a 'facilitator' parameter"
    end

    test "facilitator must be a persona name" do
      params = %{
        topic: "Test topic",
        personas: @valid_personas,
        strategy: "facilitator",
        facilitator: "Charlie"
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "must be one of the persona names"
    end

    test "rejects invalid strategy" do
      params = %{
        topic: "Test topic",
        personas: @valid_personas,
        strategy: "chaos"
      }

      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "Invalid strategy"
    end
  end

  describe "template resolution" do
    test "requires either personas or template" do
      params = %{topic: "Test topic"}
      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "Either 'personas' or 'template' must be provided"
    end

    test "rejects unknown template" do
      params = %{topic: "Test topic", template: "nonexistent"}
      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "Unknown template"
    end

    test "brainstorm template starts conversation" do
      params = %{topic: "Test topic", template: "brainstorm"}
      result = SpawnConversation.run(params, @valid_context)
      assert {:ok, %{conversation_id: _, result: result_text}} = result
      assert result_text =~ "Conversation started"
      assert result_text =~ "Innovator"
    end

    test "template with overrides applies overrides" do
      params = %{topic: "Test topic", template: "brainstorm", max_rounds: 4}
      result = SpawnConversation.run(params, @valid_context)
      assert {:ok, %{conversation_id: _, result: result_text}} = result
      assert result_text =~ "max 4 rounds"
    end

    test "template with facilitator override on non-facilitator template" do
      params = %{
        topic: "Test topic",
        template: "brainstorm",
        strategy: "facilitator",
        facilitator: "Innovator"
      }

      result = SpawnConversation.run(params, @valid_context)
      assert {:ok, %{conversation_id: _, result: result_text}} = result
      assert result_text =~ "facilitator"
    end
  end

  describe "max_rounds validation" do
    test "rejects zero max_rounds" do
      params = %{topic: "Test", personas: @valid_personas, max_rounds: 0}
      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "positive integer"
    end

    test "rejects negative max_rounds" do
      params = %{topic: "Test", personas: @valid_personas, max_rounds: -1}
      assert {:error, msg} = SpawnConversation.run(params, @valid_context)
      assert msg =~ "positive integer"
    end
  end

  describe "conversation lifecycle" do
    test "starts a conversation and returns conversation_id" do
      params = %{topic: "Cache design", personas: @valid_personas}
      assert {:ok, result} = SpawnConversation.run(params, @valid_context)
      assert is_binary(result.conversation_id)
      assert result.result =~ "Conversation started"
      assert result.result =~ "Cache design"
      assert result.result =~ "Alice"
      assert result.result =~ "Bob"
    end

    test "conversation is addressable via returned id" do
      params = %{topic: "API design", personas: @valid_personas}
      {:ok, result} = SpawnConversation.run(params, @valid_context)

      assert {:ok, context} =
               Loomkin.Conversations.Server.get_context(result.conversation_id)

      assert context.topic == "API design"
      assert length(context.participants) == 2
    end

    test "custom max_rounds is passed to conversation" do
      params = %{topic: "Quick chat", personas: @valid_personas, max_rounds: 3}
      {:ok, result} = SpawnConversation.run(params, @valid_context)
      assert result.result =~ "max 3 rounds"

      {:ok, context} =
        Loomkin.Conversations.Server.get_context(result.conversation_id)

      assert context.max_rounds == 3
    end

    test "facilitator strategy with valid facilitator starts conversation" do
      params = %{
        topic: "Design review",
        personas: @valid_personas,
        strategy: "facilitator",
        facilitator: "Alice"
      }

      assert {:ok, result} = SpawnConversation.run(params, @valid_context)
      assert result.result =~ "facilitator"
    end
  end
end
