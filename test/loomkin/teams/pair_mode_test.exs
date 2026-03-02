defmodule Loomkin.Teams.PairModeTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{PairMode, Manager, Comms}

  setup do
    {:ok, team_id} = Manager.create_team(name: "pair-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "start_pair/4" do
    test "creates a pair session and notifies agents", %{team_id: team_id} do
      Comms.subscribe(team_id, "coder1")
      Comms.subscribe(team_id, "reviewer1")

      assert {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")
      assert is_binary(pair_id)

      # Both agents receive notification
      assert_receive {:pair_started, ^pair_id, :coder, "reviewer1"}
      assert_receive {:pair_started, ^pair_id, :reviewer, "coder1"}

      # Team broadcast
      assert_receive {:pair_session_started, ^pair_id, "coder1", "reviewer1"}
    end

    test "stores pair info in ETS", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      assert {:ok, info} = PairMode.get_pair(team_id, pair_id)
      assert info.pair_id == pair_id
      assert info.coder == "coder1"
      assert info.reviewer == "reviewer1"
      assert is_integer(info.started_at)
    end

    test "returns error when coder and reviewer are the same", %{team_id: team_id} do
      assert {:error, :same_agent} = PairMode.start_pair(team_id, "alice", "alice")
    end

    test "supports task_opts", %{team_id: team_id} do
      {:ok, pair_id} =
        PairMode.start_pair(team_id, "coder1", "reviewer1",
          session_id: "sess-1",
          description: "fix auth bug"
        )

      {:ok, info} = PairMode.get_pair(team_id, pair_id)
      assert info.task_opts[:session_id] == "sess-1"
      assert info.task_opts[:description] == "fix auth bug"
    end
  end

  describe "stop_pair/2" do
    test "removes pair from ETS and notifies agents", %{team_id: team_id} do
      Comms.subscribe(team_id, "coder1")
      Comms.subscribe(team_id, "reviewer1")

      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      # Drain start notifications
      assert_receive {:pair_started, _, _, _}
      assert_receive {:pair_started, _, _, _}

      assert :ok = PairMode.stop_pair(team_id, pair_id)

      # Agents receive stop notification
      assert_receive {:pair_stopped, ^pair_id}
      assert_receive {:pair_stopped, ^pair_id}

      # Team broadcast
      assert_receive {:pair_session_stopped, ^pair_id}

      # Pair no longer in ETS
      assert :error = PairMode.get_pair(team_id, pair_id)
    end

    test "returns error for nonexistent pair", %{team_id: team_id} do
      assert {:error, :not_found} = PairMode.stop_pair(team_id, "nonexistent-id")
    end
  end

  describe "list_pairs/1" do
    test "returns empty list when no pairs exist", %{team_id: team_id} do
      assert PairMode.list_pairs(team_id) == []
    end

    test "lists all active pairs", %{team_id: team_id} do
      {:ok, _id1} = PairMode.start_pair(team_id, "coder1", "reviewer1")
      {:ok, _id2} = PairMode.start_pair(team_id, "coder2", "reviewer2")

      pairs = PairMode.list_pairs(team_id)
      assert length(pairs) == 2

      coders = Enum.map(pairs, & &1.coder) |> Enum.sort()
      assert coders == ["coder1", "coder2"]
    end

    test "does not include stopped pairs", %{team_id: team_id} do
      {:ok, id1} = PairMode.start_pair(team_id, "coder1", "reviewer1")
      {:ok, _id2} = PairMode.start_pair(team_id, "coder2", "reviewer2")

      PairMode.stop_pair(team_id, id1)

      pairs = PairMode.list_pairs(team_id)
      assert length(pairs) == 1
      assert hd(pairs).coder == "coder2"
    end
  end

  describe "get_pair/2" do
    test "returns pair info for valid pair_id", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      assert {:ok, info} = PairMode.get_pair(team_id, pair_id)
      assert info.pair_id == pair_id
      assert info.coder == "coder1"
      assert info.reviewer == "reviewer1"
    end

    test "returns :error for unknown pair_id", %{team_id: team_id} do
      assert :error = PairMode.get_pair(team_id, "unknown-id")
    end
  end

  describe "broadcast_event/5" do
    test "broadcasts event on pair topic", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      # Subscribe to the pair topic
      topic = "team:#{team_id}:pair:#{pair_id}"
      Phoenix.PubSub.subscribe(Loomkin.PubSub, topic)

      PairMode.broadcast_event(team_id, pair_id, :intent_broadcast, "coder1", %{
        intent: "refactor auth module"
      })

      assert_receive {:pair_event, message}
      assert message.event == :intent_broadcast
      assert message.from == "coder1"
      assert message.pair_id == pair_id
      assert message.payload.intent == "refactor auth module"
      assert is_integer(message.timestamp)
    end

    test "supports all event types", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")
      topic = "team:#{team_id}:pair:#{pair_id}"
      Phoenix.PubSub.subscribe(Loomkin.PubSub, topic)

      events = [:intent_broadcast, :file_edited, :review_feedback, :review_approved, :review_rejected]

      Enum.each(events, fn event_type ->
        PairMode.broadcast_event(team_id, pair_id, event_type, "coder1")
        assert_receive {:pair_event, %{event: ^event_type}}
      end)
    end
  end

  describe "log_feedback/5" do
    test "creates observation node in decision graph", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      {:ok, node} =
        PairMode.log_feedback(
          team_id,
          pair_id,
          "reviewer1",
          "Missing error handling in auth flow",
          confidence: 80
        )

      assert node.node_type == :observation
      assert node.agent_name == "reviewer1"
      assert node.description == "Missing error handling in auth flow"
      assert node.confidence == 80
      # Ecto SQLite stores map keys as strings after JSON round-trip
      pair_id_val = node.metadata["pair_id"] || node.metadata[:pair_id]
      type_val = node.metadata["type"] || node.metadata[:type]
      assert pair_id_val == pair_id
      assert type_val == "pair_review"
    end

    test "broadcasts decision event", %{team_id: team_id} do
      Comms.subscribe(team_id, "reviewer1")

      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      {:ok, node} =
        PairMode.log_feedback(team_id, pair_id, "reviewer1", "Looks good overall")

      assert_receive {:decision_logged, node_id, "reviewer1"}
      assert node_id == node.id
    end

    test "creates node without session_id by default", %{team_id: team_id} do
      {:ok, pair_id} = PairMode.start_pair(team_id, "coder1", "reviewer1")

      {:ok, node} =
        PairMode.log_feedback(
          team_id,
          pair_id,
          "reviewer1",
          "Test feedback"
        )

      assert node.session_id == nil
      assert node.node_type == :observation
    end
  end
end
