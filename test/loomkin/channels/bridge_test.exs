defmodule Loomkin.Channels.BridgeTest do
  use ExUnit.Case, async: false

  import Mox

  alias Loomkin.Channels.Bridge

  @pubsub Loomkin.PubSub

  setup :verify_on_exit!

  setup do
    channel_id = "test-chat-#{System.unique_integer([:positive])}"
    team_id = "bridge-test-team-#{System.unique_integer([:positive])}"

    binding = %{
      channel: :telegram,
      channel_id: channel_id,
      team_id: team_id
    }

    # Global mode since the GenServer runs in a separate process
    Mox.set_mox_global()

    # Stub all adapter callbacks by default
    stub(Loomkin.MockAdapter, :send_text, fn _binding, _text, _opts -> :ok end)
    stub(Loomkin.MockAdapter, :send_question, fn _binding, _qid, _question, _options -> :ok end)
    stub(Loomkin.MockAdapter, :send_activity, fn _binding, _event -> :ok end)

    stub(Loomkin.MockAdapter, :format_agent_message, fn name, content ->
      "[#{name}] #{content}"
    end)

    stub(Loomkin.MockAdapter, :parse_inbound, fn _ -> :ignore end)

    {:ok, pid} = Bridge.start_link(binding: binding, adapter: Loomkin.MockAdapter)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
    end)

    %{pid: pid, binding: binding, channel_id: channel_id, team_id: team_id}
  end

  describe "start_link/1 and lookup/2" do
    test "registers in the registry", %{binding: binding} do
      assert {:ok, _pid} = Bridge.lookup(binding.channel, binding.channel_id)
    end

    test "subscribes to team PubSub topics", %{team_id: team_id, pid: pid} do
      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        assert text =~ "has been dissolved"
        assert text =~ team_id
        :ok
      end)

      Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", :team_dissolved)
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count >= 1
    end

    test "subscribes to telemetry topic", %{team_id: team_id, pid: pid} do
      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        assert text =~ "Budget warning"
        :ok
      end)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "telemetry:team:#{team_id}",
        {:team_budget_warning, %{spent: 8.0, limit: 10.0, threshold: 80}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count >= 1
    end
  end

  describe "PubSub event forwarding" do
    test "forwards ask_user_question to adapter", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_question, fn _binding, _qid, question, options ->
        send(test_pid, {:question_sent, question, options})
        :ok
      end)

      payload = %{
        question_id: "q-1",
        agent_name: "researcher",
        question: "Which approach?",
        options: ["A", "B"]
      }

      send(pid, {:ask_user_question, payload})

      assert_receive {:question_sent, question, ["A", "B"]}, 500
      assert question =~ "researcher"
      assert question =~ "Which approach?"

      state = :sys.get_state(pid)
      assert Map.has_key?(state.pending_questions, "q-1")
      assert state.pending_questions["q-1"] == %{agent_name: "researcher"}
    end

    test "forwards agent_error to adapter with team_id", %{pid: pid, team_id: team_id} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, {:agent_error, %{agent_name: "coder", error: "timeout"}})

      assert_receive {:text_sent, text}, 500
      assert text =~ "coder"
      assert text =~ "timeout"
      assert text =~ "`#{team_id}`"
    end

    test "forwards team_dissolved to adapter with team_id", %{pid: pid, team_id: team_id} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, :team_dissolved)

      assert_receive {:text_sent, text}, 500
      assert text =~ "has been dissolved"
      assert text =~ "`#{team_id}`"
    end

    test "forwards assistant messages to adapter", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :format_agent_message, fn name, content ->
        "[#{name}] #{content}"
      end)

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, {:new_message, %{role: :assistant, content: "Hello user", agent_name: "lead"}})

      assert_receive {:text_sent, "[lead] Hello user"}, 500
    end

    test "does not forward tool messages", %{pid: pid} do
      send(pid, {:new_message, %{role: :tool, content: "tool result", agent_name: "lead"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "does not forward empty assistant messages", %{pid: pid} do
      send(pid, {:new_message, %{role: :assistant, content: "", agent_name: "lead"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "forwards actionable collab events", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_activity, fn _binding, event ->
        send(test_pid, {:activity_sent, event})
        :ok
      end)

      event = %{type: :conflict_detected, agents: ["a", "b"]}
      send(pid, {:collab_event, event})

      assert_receive {:activity_sent, ^event}, 500
    end

    test "suppresses info-level collab events at default levels", %{pid: pid} do
      send(pid, {:collab_event, %{type: :discovery_shared, agents: ["a"]}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses noisy events", %{pid: pid} do
      for event <- [:stream_delta, :tool_executing, :usage] do
        send(pid, {event, %{}})
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end
  end

  describe "permission_request forwarding" do
    test "registers in PermissionRegistry and sends approval instructions", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(
        pid,
        {:permission_request, "team-x", "write_file", "/a.ex", {:agent, "team-x", "coder"}}
      )

      assert_receive {:text_sent, text}, 500
      assert text =~ "Permission request"
      assert text =~ "coder"
      assert text =~ "write_file"
      assert text =~ "/approve"
    end
  end

  describe "telemetry event forwarding" do
    test "forwards team_budget_warning with team_id", %{pid: pid, team_id: team_id} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, {:team_budget_warning, %{spent: 5.0, limit: 10.0, threshold: 80}})

      assert_receive {:text_sent, text}, 500
      assert text =~ "Budget warning"
      assert text =~ "80%"
      assert text =~ "`#{team_id}`"
    end

    test "forwards team_escalation", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(
        pid,
        {:team_escalation, %{agent_name: "coder", from_model: "haiku", to_model: "sonnet"}}
      )

      assert_receive {:text_sent, text}, 500
      assert text =~ "coder"
      assert text =~ "Escalated"
      assert text =~ "haiku"
      assert text =~ "sonnet"
    end

    test "suppresses team_llm_stop at default levels", %{pid: pid} do
      send(
        pid,
        {:team_llm_stop,
         %{
           agent_name: "coder",
           model: "haiku",
           cost: 0.001,
           input_tokens: 100,
           output_tokens: 50
         }}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end
  end

  describe "session event forwarding" do
    test "forwards session_cancelled with monospace session_id", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, {:session_cancelled, "sess-1"})

      assert_receive {:text_sent, text}, 500
      assert text =~ "`sess-1`"
      assert text =~ "cancelled"
    end

    test "forwards llm_error", %{pid: pid} do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send(pid, {:llm_error, "sess-1", "API timeout"})

      assert_receive {:text_sent, text}, 500
      assert text =~ "LLM Error"
      assert text =~ "API timeout"
    end

    test "suppresses session_status at default levels", %{pid: pid} do
      send(pid, {:session_status, "sess-1", :running})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses team_available at default levels", %{pid: pid} do
      send(pid, {:team_available, "sess-1", "team-1"})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses noise events from sessions", %{pid: pid} do
      for event <- [
            {:stream_start, "s"},
            {:stream_end, "s"},
            {:stream_delta, "s", %{text: "hi"}}
          ] do
        send(pid, event)
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end
  end

  describe "inbound message handling" do
    test "routes parsed message via cast", %{binding: binding} do
      expect(Loomkin.MockAdapter, :parse_inbound, fn raw ->
        assert raw == %{"text" => "hello"}
        {:message, "hello", %{}}
      end)

      assert :ok =
               Bridge.handle_inbound(binding.channel, binding.channel_id, %{"text" => "hello"})

      Process.sleep(50)
    end

    test "routes callback via cast", %{binding: binding, pid: pid} do
      expect(Loomkin.MockAdapter, :send_question, fn _b, _qid, _q, _o -> :ok end)

      send(
        pid,
        {:ask_user_question,
         %{
           question_id: "q-callback",
           agent_name: "coder",
           question: "Pick one",
           options: ["X", "Y"]
         }}
      )

      Process.sleep(50)

      assert :ok =
               Bridge.handle_callback(binding.channel, binding.channel_id, "q-callback", "X")

      Process.sleep(50)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.pending_questions, "q-callback")
    end

    test "returns error when no bridge exists" do
      assert {:error, :no_bridge} = Bridge.handle_inbound(:telegram, "nonexistent", %{})
      assert {:error, :no_bridge} = Bridge.handle_callback(:telegram, "nonexistent", "q", "d")
    end
  end

  describe "subscribe_session/3" do
    test "tracks subscribed sessions in state", %{binding: binding, pid: pid} do
      Bridge.subscribe_session(binding.channel, binding.channel_id, "sess-dynamic")
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.subscribed_sessions, "sess-dynamic")
    end

    test "is idempotent", %{binding: binding, pid: pid} do
      Bridge.subscribe_session(binding.channel, binding.channel_id, "sess-dup")
      Bridge.subscribe_session(binding.channel, binding.channel_id, "sess-dup")
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert MapSet.size(state.subscribed_sessions) == 1
    end

    test "receives events after subscribing", %{binding: binding, pid: pid} do
      test_pid = self()

      Bridge.subscribe_session(binding.channel, binding.channel_id, "sess-live")
      Process.sleep(50)

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "session:sess-live",
        {:session_cancelled, "sess-live"}
      )

      assert_receive {:text_sent, text}, 500
      assert text =~ "sess-live"
    end

    test "returns error for unknown bridge" do
      assert {:error, :no_bridge} =
               Bridge.subscribe_session(:telegram, "unknown-channel", "sess-1")
    end
  end

  describe "init session subscription from config" do
    test "subscribes to session when session_id in config" do
      channel_id = "test-cfg-session-#{System.unique_integer([:positive])}"

      binding = %{
        channel: :telegram,
        channel_id: channel_id,
        team_id: "bridge-cfg-team-#{System.unique_integer([:positive])}",
        config: %{"session_id" => "sess-from-config"}
      }

      {:ok, pid} = Bridge.start_link(binding: binding, adapter: Loomkin.MockAdapter)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      end)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.subscribed_sessions, "sess-from-config")
    end

    test "handles nil config gracefully" do
      channel_id = "test-nil-cfg-#{System.unique_integer([:positive])}"

      binding = %{
        channel: :telegram,
        channel_id: channel_id,
        team_id: "bridge-nil-team-#{System.unique_integer([:positive])}",
        config: nil
      }

      {:ok, pid} = Bridge.start_link(binding: binding, adapter: Loomkin.MockAdapter)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      end)

      state = :sys.get_state(pid)
      assert MapSet.size(state.subscribed_sessions) == 0
    end
  end

  describe "severity-based filtering with custom levels" do
    test "forwards info events when notify levels include info" do
      channel_id = "test-info-#{System.unique_integer([:positive])}"
      test_pid = self()

      binding = %{
        channel: :telegram,
        channel_id: channel_id,
        team_id: "bridge-info-team-#{System.unique_integer([:positive])}",
        config: %{"notify" => ["urgent", "action", "info"]}
      }

      {:ok, pid} = Bridge.start_link(binding: binding, adapter: Loomkin.MockAdapter)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      end)

      expect(Loomkin.MockAdapter, :send_activity, fn _binding, _event ->
        send(test_pid, :info_sent)
        :ok
      end)

      send(pid, {:collab_event, %{type: :discovery_shared, agents: ["a"]}})

      assert_receive :info_sent, 500
    end
  end

  describe "rate limiting" do
    test "allows messages up to the limit", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> :ok end)

      for i <- 1..15 do
        send(pid, {:agent_error, %{agent_name: "agent", error: "err-#{i}"}})
      end

      Process.sleep(100)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 15
    end

    test "drops messages after rate limit exceeded", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> :ok end)

      for i <- 1..20 do
        send(pid, {:agent_error, %{agent_name: "agent", error: "err-#{i}"}})
      end

      Process.sleep(100)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 15
    end

    test "handles adapter send failure gracefully", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> {:error, :network_error} end)

      send(pid, {:agent_error, %{agent_name: "agent", error: "err"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 1
    end
  end
end
