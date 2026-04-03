defmodule Loomkin.Teams.ContextKeeperTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.ContextKeeper

  setup do
    # Ensure supervisor tree is available
    on_exit(fn ->
      # Clean up any keepers we spawned (supervisor may already be down during teardown)
      if Process.whereis(Loomkin.Teams.AgentSupervisor) do
        DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
        |> Enum.each(fn {_, pid, _, _} ->
          DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
        end)
      end
    end)

    :ok
  end

  defp start_keeper(opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    team_id = Keyword.get(opts, :team_id, "test-team-#{System.unique_integer([:positive])}")
    topic = Keyword.get(opts, :topic, "test topic")
    source_agent = Keyword.get(opts, :source_agent, "test-agent")
    messages = Keyword.get(opts, :messages, [])
    metadata = Keyword.get(opts, :metadata, %{})
    persist_debounce_ms = Keyword.get(opts, :persist_debounce_ms, 0)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loomkin.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id,
         team_id: team_id,
         topic: topic,
         source_agent: source_agent,
         messages: messages,
         metadata: metadata,
         persist_debounce_ms: persist_debounce_ms}
      )

    %{pid: pid, id: id, team_id: team_id}
  end

  describe "start_link/1" do
    test "starts and registers in Keepers.Registry" do
      %{pid: pid, team_id: team_id, id: id} = start_keeper()

      assert Process.alive?(pid)

      # Check registry
      assert [{^pid, meta}] =
               Registry.lookup(Loomkin.Keepers.Registry, {team_id, id})

      assert meta.type == :keeper
    end

    test "starts with provided messages" do
      messages = [
        %{role: :user, content: "hello world"},
        %{role: :assistant, content: "hi there"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, retrieved} = ContextKeeper.retrieve_all(pid)
      assert length(retrieved) == 2
    end
  end

  describe "store/3" do
    test "appends messages" do
      %{pid: pid} = start_keeper()

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "first"}])
      :ok = ContextKeeper.store(pid, [%{role: :user, content: "second"}])

      {:ok, messages} = ContextKeeper.retrieve_all(pid)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "first"
      assert Enum.at(messages, 1).content == "second"
    end

    test "merges metadata" do
      %{pid: pid} = start_keeper(metadata: %{"tag" => "original"})

      :ok = ContextKeeper.store(pid, [], %{"extra" => "value"})

      state = ContextKeeper.get_state(pid)
      assert state.metadata["tag"] == "original"
      assert state.metadata["extra"] == "value"
    end

    test "updates token count" do
      %{pid: pid} = start_keeper()

      content = String.duplicate("a", 400)
      :ok = ContextKeeper.store(pid, [%{role: :user, content: content}])

      state = ContextKeeper.get_state(pid)
      assert state.token_count > 0
    end
  end

  describe "retrieve_all/1" do
    test "returns all messages" do
      messages = [
        %{role: :user, content: "one"},
        %{role: :assistant, content: "two"},
        %{role: :user, content: "three"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve_all(pid)
      assert length(result) == 3
    end

    test "returns empty list when no messages" do
      %{pid: pid} = start_keeper()

      {:ok, result} = ContextKeeper.retrieve_all(pid)
      assert result == []
    end
  end

  describe "retrieve/2" do
    test "returns all messages when under token threshold" do
      messages = [
        %{role: :user, content: "hello elixir"},
        %{role: :assistant, content: "hi genserver"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve(pid, "elixir")
      assert length(result) == 2
    end

    test "does keyword matching when over token threshold" do
      # Create messages totaling > 10K tokens (~40K chars)
      filler = String.duplicate("filler content padding ", 500)

      messages =
        Enum.map(1..10, fn i ->
          %{role: :user, content: "message #{i} #{filler}"}
        end) ++
          [%{role: :user, content: "elixir genserver phoenix liveview specific topic"}]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve(pid, "elixir genserver")
      # Should return the specific topic message (highest keyword overlap)
      assert length(result) > 0
    end
  end

  describe "index_entry/1" do
    test "returns formatted index string" do
      %{pid: pid, id: id} = start_keeper(topic: "code review", source_agent: "researcher")

      entry = ContextKeeper.index_entry(pid)
      assert entry =~ "Keeper:#{id}"
      assert entry =~ "topic=code review"
      assert entry =~ "source=researcher"
      assert entry =~ "tokens="
    end
  end

  describe "get_state/1" do
    test "returns full state as map" do
      %{pid: pid, id: id, team_id: team_id} =
        start_keeper(topic: "debug", source_agent: "coder", metadata: %{"key" => "val"})

      state = ContextKeeper.get_state(pid)
      assert state.id == id
      assert state.team_id == team_id
      assert state.topic == "debug"
      assert state.source_agent == "coder"
      assert state.metadata == %{"key" => "val"}
      assert %DateTime{} = state.created_at
    end
  end

  describe "smart_retrieve/2" do
    @tag :llm_dependent
    test "falls back to keyword retrieval when LLM is unavailable" do
      messages = [
        %{role: :user, content: "elixir is great for concurrency"},
        %{role: :assistant, content: "yes, the BEAM VM handles it well"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      # LLM call will fail in test env (no API key), triggering fallback
      {:ok, result} = ContextKeeper.smart_retrieve(pid, "what is elixir good at?")

      # Fallback returns formatted text (not raw message list)
      assert is_binary(result)
      assert result =~ "elixir"
      assert result =~ "BEAM"
    end

    @tag :llm_dependent
    test "does not modify state after smart retrieval" do
      messages = [
        %{role: :user, content: "hello world"},
        %{role: :assistant, content: "hi there"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      state_before = ContextKeeper.get_state(pid)

      {:ok, _result} = ContextKeeper.smart_retrieve(pid, "what was said?")

      state_after = ContextKeeper.get_state(pid)

      assert state_before.messages == state_after.messages
      assert state_before.token_count == state_after.token_count
      assert state_before.metadata == state_after.metadata
    end

    @tag :llm_dependent
    test "returns ok tuple on fallback" do
      %{pid: pid} = start_keeper(messages: [%{role: :user, content: "test content"}])

      assert {:ok, _result} = ContextKeeper.smart_retrieve(pid, "anything")
    end
  end

  describe "persistence" do
    test "persists to database on store" do
      id = Ecto.UUID.generate()
      %{pid: pid} = start_keeper(id: id)

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "persist me"}])

      :ok = ContextKeeper.flush_persist(pid)

      record = Repo.get(Loomkin.Schemas.ContextKeeper, id)
      assert record
      assert record.topic
      assert record.status == :active
      assert record.messages["messages"] == [%{"role" => "user", "content" => "persist me"}]
    end

    test "coalesces rapid stores into single persist" do
      id = Ecto.UUID.generate()
      %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 100)

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-1"}])
      :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-2"}])
      :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-3"}])

      :ok = ContextKeeper.flush_persist(pid)

      record = Repo.get(Loomkin.Schemas.ContextKeeper, id)
      assert length(record.messages["messages"]) == 3
    end

    test "reloads state from database on restart" do
      id = Ecto.UUID.generate()
      team_id = "test-team-#{System.unique_integer([:positive])}"

      %{pid: pid} = start_keeper(id: id, team_id: team_id)
      :ok = ContextKeeper.store(pid, [%{role: :user, content: "survive crash"}])
      :ok = ContextKeeper.flush_persist(pid)
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      %{pid: pid2} = start_keeper(id: id, team_id: team_id)
      {:ok, messages} = ContextKeeper.retrieve_all(pid2)
      assert length(messages) == 1
      assert hd(messages)["content"] == "survive crash"
    end

    test "terminate persists dirty state" do
      id = Ecto.UUID.generate()
      %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 60_000)

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "final state"}])

      # Use GenServer.stop which calls terminate/2 synchronously before exit.
      # The DynamicSupervisor will see a :normal exit and not restart (:permanent
      # restarts on abnormal exits; :normal is not abnormal for stop).
      # Actually :permanent restarts on all exits including :normal — but we
      # monitor to wait for full cleanup before checking DB.
      ref = Process.monitor(pid)
      GenServer.stop(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      record = Repo.get(Loomkin.Schemas.ContextKeeper, id)
      assert record
      assert record.messages["messages"] == [%{"role" => "user", "content" => "final state"}]
    end
  end
end
