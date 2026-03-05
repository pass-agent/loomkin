defmodule Loomkin.Teams.ContextRetrievalTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ContextKeeper, ContextRetrieval, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "retrieval-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp spawn_keeper(team_id, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    topic = Keyword.get(opts, :topic, "test topic")
    source_agent = Keyword.get(opts, :source_agent, "test-agent")
    messages = Keyword.get(opts, :messages, [])

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loomkin.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id, team_id: team_id, topic: topic, source_agent: source_agent, messages: messages}
      )

    %{pid: pid, id: id}
  end

  describe "list_keepers/1" do
    test "returns empty list when no keepers", %{team_id: team_id} do
      assert ContextRetrieval.list_keepers(team_id) == []
    end

    test "lists all keepers for a team", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "topic A", source_agent: "agent-1")
      spawn_keeper(team_id, topic: "topic B", source_agent: "agent-2")

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 2

      topics = Enum.map(keepers, & &1.topic) |> Enum.sort()
      assert topics == ["topic A", "topic B"]
    end

    test "does not include keepers from other teams", %{team_id: team_id} do
      {:ok, other_team_id} = Manager.create_team(name: "other-team")

      spawn_keeper(team_id, topic: "my topic")
      spawn_keeper(other_team_id, topic: "other topic")

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "my topic"

      # Clean up other team
      Loomkin.Teams.TableRegistry.delete_table(other_team_id)
    end

    test "does not include regular agents", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "keeper topic")

      # Register a regular agent (not a keeper)
      Registry.register(
        Loomkin.Teams.AgentRegistry,
        {team_id, "regular-agent"},
        %{role: :coder, status: :idle}
      )

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "keeper topic"
    end
  end

  describe "search/2" do
    test "returns keepers sorted by relevance", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "elixir genserver patterns")
      spawn_keeper(team_id, topic: "javascript react hooks")
      spawn_keeper(team_id, topic: "elixir phoenix liveview")

      results = ContextRetrieval.search(team_id, "elixir phoenix")

      assert length(results) == 3
      # The elixir phoenix liveview keeper should score highest (2 word overlap)
      first = hd(results)
      assert first.topic == "elixir phoenix liveview"
      assert first.relevance == 2
    end

    test "returns empty list when no keepers", %{team_id: team_id} do
      assert ContextRetrieval.search(team_id, "anything") == []
    end
  end

  describe "retrieve/3" do
    test "retrieves from specific keeper by id", %{team_id: team_id} do
      messages = [%{role: :user, content: "specific content here"}]
      %{id: id} = spawn_keeper(team_id, topic: "specific", messages: messages)

      {:ok, result} = ContextRetrieval.retrieve(team_id, "specific", keeper_id: id)
      assert length(result) == 1
      assert hd(result).content == "specific content here"
    end

    test "retrieves from best matching keeper when no keeper_id", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "database schema design",
        messages: [%{role: :user, content: "schema stuff"}]
      )

      spawn_keeper(team_id,
        topic: "api endpoint testing",
        messages: [%{role: :user, content: "api stuff"}]
      )

      {:ok, result} = ContextRetrieval.retrieve(team_id, "database schema")
      assert length(result) == 1
      assert hd(result).content == "schema stuff"
    end

    test "returns error when keeper not found", %{team_id: team_id} do
      assert {:error, :not_found} =
               ContextRetrieval.retrieve(team_id, "anything", keeper_id: Ecto.UUID.generate())
    end

    test "returns error when no keepers exist", %{team_id: team_id} do
      assert {:error, :not_found} = ContextRetrieval.retrieve(team_id, "anything")
    end

    test "explicit mode: :raw uses raw retrieval", %{team_id: team_id} do
      messages = [%{role: :user, content: "raw content here"}]
      %{id: id} = spawn_keeper(team_id, topic: "raw test", messages: messages)

      {:ok, result} =
        ContextRetrieval.retrieve(team_id, "what is raw test?", keeper_id: id, mode: :raw)

      assert length(result) == 1
      assert hd(result).content == "raw content here"
    end

    test "explicit mode: :smart uses smart retrieval", %{team_id: team_id} do
      messages = [%{role: :user, content: "smart content here"}]
      %{id: id} = spawn_keeper(team_id, topic: "smart test", messages: messages)

      # This test depends on ContextKeeper.smart_retrieve/2 from Task #1.
      # It will fail until that function is available.
      {:ok, result} =
        ContextRetrieval.retrieve(team_id, "keywords only", keeper_id: id, mode: :smart)

      assert is_binary(result) or is_list(result)
    end
  end

  describe "smart_retrieve/3" do
    test "forces smart mode", %{team_id: team_id} do
      messages = [%{role: :user, content: "smart retrieval content"}]
      %{id: id} = spawn_keeper(team_id, topic: "smart topic", messages: messages)

      # This test depends on ContextKeeper.smart_retrieve/2 from Task #1.
      {:ok, result} = ContextRetrieval.smart_retrieve(team_id, "smart topic", keeper_id: id)
      assert is_binary(result) or is_list(result)
    end

    test "returns error when no keepers exist", %{team_id: team_id} do
      assert {:error, :not_found} = ContextRetrieval.smart_retrieve(team_id, "anything")
    end
  end

  describe "synthesize/2" do
    test "returns error when no keepers match", %{team_id: team_id} do
      assert {:error, :not_found} = ContextRetrieval.synthesize(team_id, "nonexistent")
    end

    test "returns error when no keepers exist", %{team_id: team_id} do
      assert {:error, :not_found} = ContextRetrieval.synthesize(team_id, "anything")
    end

    test "returns synthesized answer from multiple keepers", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "auth implementation",
        source_agent: "researcher",
        messages: [%{role: :user, content: "We use JWT tokens for auth"}]
      )

      spawn_keeper(team_id,
        topic: "auth testing",
        source_agent: "tester",
        messages: [%{role: :user, content: "Auth tests cover login and logout"}]
      )

      # The LLM call fails in test (no API key), so fallback returns raw keeper context
      {:ok, result} = ContextRetrieval.synthesize(team_id, "auth")
      assert is_binary(result)
      assert result =~ "JWT tokens" or result =~ "login and logout"
    end

    test "skips keepers with zero relevance", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "database schema",
        source_agent: "coder",
        messages: [%{role: :user, content: "PostgreSQL tables"}]
      )

      assert {:error, :not_found} = ContextRetrieval.synthesize(team_id, "authentication")
    end
  end

  describe "detect_mode/1" do
    test "question mark triggers smart mode" do
      assert ContextRetrieval.detect_mode("what is this?") == :smart
      assert ContextRetrieval.detect_mode("tell me about this?") == :smart
      assert ContextRetrieval.detect_mode("anything at all?") == :smart
    end

    test "question starter words trigger smart mode" do
      assert ContextRetrieval.detect_mode("what is the architecture") == :smart
      assert ContextRetrieval.detect_mode("how does the pipeline work") == :smart
      assert ContextRetrieval.detect_mode("why is this failing") == :smart
      assert ContextRetrieval.detect_mode("where is the config") == :smart
      assert ContextRetrieval.detect_mode("when was this created") == :smart
      assert ContextRetrieval.detect_mode("who owns this module") == :smart
      assert ContextRetrieval.detect_mode("which pattern is used") == :smart
      assert ContextRetrieval.detect_mode("did the test pass") == :smart
      assert ContextRetrieval.detect_mode("does this work") == :smart
      assert ContextRetrieval.detect_mode("is this correct") == :smart
      assert ContextRetrieval.detect_mode("are there any bugs") == :smart
      assert ContextRetrieval.detect_mode("was this deployed") == :smart
      assert ContextRetrieval.detect_mode("were the changes applied") == :smart
      assert ContextRetrieval.detect_mode("can we refactor this") == :smart
      assert ContextRetrieval.detect_mode("could this be improved") == :smart
      assert ContextRetrieval.detect_mode("should we use genserver") == :smart
      assert ContextRetrieval.detect_mode("would this approach work") == :smart
    end

    test "plain keywords trigger raw mode" do
      assert ContextRetrieval.detect_mode("elixir genserver") == :raw
      assert ContextRetrieval.detect_mode("database schema") == :raw
      assert ContextRetrieval.detect_mode("config settings") == :raw
    end

    test "handles leading/trailing whitespace" do
      assert ContextRetrieval.detect_mode("  what is this  ") == :smart
      assert ContextRetrieval.detect_mode("  keywords  ") == :raw
    end

    test "case insensitive detection" do
      assert ContextRetrieval.detect_mode("What is this") == :smart
      assert ContextRetrieval.detect_mode("HOW does this work") == :smart
      assert ContextRetrieval.detect_mode("WHERE is the config") == :smart
    end

    test "does not match question words mid-sentence" do
      assert ContextRetrieval.detect_mode("tell me what") == :raw
      assert ContextRetrieval.detect_mode("show how") == :raw
    end
  end
end
