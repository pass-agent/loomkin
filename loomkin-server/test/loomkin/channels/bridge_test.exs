defmodule Loomkin.Channels.BridgeTest do
  use ExUnit.Case, async: false

  import Mox

  alias Loomkin.Channels.Bridge

  setup :verify_on_exit!

  defp signal(type, data) do
    %Jido.Signal{
      id: Ecto.UUID.generate(),
      type: type,
      data: data,
      source: "test",
      specversion: "1.0.2",
      datacontenttype: "application/json"
    }
  end

  defp send_signal(pid, type, data \\ %{}) do
    send(pid, {:signal, signal(type, data)})
  end

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

      # Publish a signal that the Bridge is subscribed to
      sig = signal("team.dissolved", %{team_id: team_id})
      Loomkin.Signals.publish(sig)
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count >= 1
    end

    test "subscribes to telemetry topic", %{pid: pid} do
      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        assert text =~ "Budget warning"
        :ok
      end)

      sig = signal("team.budget.warning", %{spent: 8.0, limit: 10.0, threshold: 80})
      Loomkin.Signals.publish(sig)
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

      send_signal(pid, "team.ask_user.question", %{
        question_id: "q-1",
        agent_name: "researcher",
        question: "Which approach?",
        options: ["A", "B"]
      })

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

      send_signal(pid, "agent.error", %{agent_name: "coder", error: "timeout"})

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

      send_signal(pid, "team.dissolved", %{team_id: team_id})

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

      send_signal(pid, "session.message.new", %{
        role: :assistant,
        content: "Hello user",
        agent_name: "lead"
      })

      assert_receive {:text_sent, "[lead] Hello user"}, 500
    end

    test "does not forward tool messages", %{pid: pid} do
      send_signal(pid, "session.message.new", %{
        role: :tool,
        content: "tool result",
        agent_name: "lead"
      })

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "does not forward empty assistant messages", %{pid: pid} do
      send_signal(pid, "session.message.new", %{role: :assistant, content: "", agent_name: "lead"})

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
      send_signal(pid, "collaboration.peer.message", %{message: {:collab_event, event}})

      assert_receive {:activity_sent, ^event}, 500
    end

    test "suppresses info-level collab events at default levels", %{pid: pid} do
      event = %{type: :discovery_shared, agents: ["a"]}
      send_signal(pid, "collaboration.peer.message", %{message: {:collab_event, event}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses noisy events", %{pid: pid} do
      for type <- ["agent.stream.delta", "agent.tool.executing", "agent.usage"] do
        send_signal(pid, type)
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end
  end

  describe "permission_request forwarding" do
    test "registers in PermissionRegistry and sends approval instructions", %{
      pid: pid,
      team_id: team_id
    } do
      test_pid = self()

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send_signal(pid, "team.permission.request", %{
        team_id: team_id,
        tool_name: "write_file",
        tool_path: "/a.ex",
        agent_name: "coder"
      })

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

      send_signal(pid, "team.budget.warning", %{spent: 5.0, limit: 10.0, threshold: 80})

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

      send_signal(pid, "agent.escalation", %{
        agent_name: "coder",
        from_model: "haiku",
        to_model: "sonnet"
      })

      assert_receive {:text_sent, text}, 500
      assert text =~ "coder"
      assert text =~ "Escalated"
      assert text =~ "haiku"
      assert text =~ "sonnet"
    end

    test "suppresses team_llm_stop at default levels", %{pid: pid} do
      send_signal(pid, "team.llm.stop", %{
        agent_name: "coder",
        model: "haiku",
        cost: 0.001,
        input_tokens: 100,
        output_tokens: 50
      })

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end
  end

  describe "session event forwarding" do
    test "forwards session_cancelled with monospace session_id", %{pid: pid, binding: binding} do
      test_pid = self()
      session_id = "sess-cancel-#{System.unique_integer([:positive])}"
      Bridge.subscribe_session(binding.channel, binding.channel_id, session_id)
      Process.sleep(50)

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send_signal(pid, "session.cancelled", %{session_id: session_id})

      assert_receive {:text_sent, text}, 500
      assert text =~ "`#{session_id}`"
      assert text =~ "cancelled"
    end

    test "forwards llm_error", %{pid: pid, binding: binding} do
      test_pid = self()
      session_id = "sess-llm-#{System.unique_integer([:positive])}"
      Bridge.subscribe_session(binding.channel, binding.channel_id, session_id)
      Process.sleep(50)

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      send_signal(pid, "session.llm.error", %{session_id: session_id, error: "API timeout"})

      assert_receive {:text_sent, text}, 500
      assert text =~ "LLM Error"
      assert text =~ "API timeout"
    end

    test "suppresses session_status at default levels", %{pid: pid, binding: binding} do
      session_id = "sess-status-#{System.unique_integer([:positive])}"
      Bridge.subscribe_session(binding.channel, binding.channel_id, session_id)
      Process.sleep(50)

      send_signal(pid, "session.status.changed", %{session_id: session_id, status: :running})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses team_available at default levels", %{pid: pid, binding: binding} do
      session_id = "sess-avail-#{System.unique_integer([:positive])}"
      Bridge.subscribe_session(binding.channel, binding.channel_id, session_id)
      Process.sleep(50)

      send_signal(pid, "session.team.available", %{
        session_id: session_id,
        team_id: "team-1"
      })

      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 0
    end

    test "suppresses noise events from sessions", %{pid: pid} do
      for {type, data} <- [
            {"agent.stream.start", %{}},
            {"agent.stream.end", %{}},
            {"agent.stream.delta", %{text: "hi"}}
          ] do
        send_signal(pid, type, data)
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

      send_signal(pid, "team.ask_user.question", %{
        question_id: "q-callback",
        agent_name: "coder",
        question: "Pick one",
        options: ["X", "Y"]
      })

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

    test "receives events after subscribing", %{binding: binding, pid: _pid} do
      test_pid = self()

      Bridge.subscribe_session(binding.channel, binding.channel_id, "sess-live")
      Process.sleep(50)

      expect(Loomkin.MockAdapter, :send_text, fn _binding, text, _opts ->
        send(test_pid, {:text_sent, text})
        :ok
      end)

      # Publish a session.cancelled signal — Bridge subscribes to "session.**"
      sig = signal("session.cancelled", %{session_id: "sess-live"})
      Loomkin.Signals.publish(sig)

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

      event = %{type: :discovery_shared, agents: ["a"]}

      send(
        pid,
        {:signal, signal("collaboration.peer.message", %{message: {:collab_event, event}})}
      )

      assert_receive :info_sent, 500
    end
  end

  describe "rate limiting" do
    test "allows messages up to the limit", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> :ok end)

      for i <- 1..15 do
        send_signal(pid, "agent.error", %{agent_name: "agent", error: "err-#{i}"})
      end

      Process.sleep(100)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 15
    end

    test "drops messages after rate limit exceeded", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> :ok end)

      for i <- 1..20 do
        send_signal(pid, "agent.error", %{agent_name: "agent", error: "err-#{i}"})
      end

      Process.sleep(100)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 15
    end

    test "handles adapter send failure gracefully", %{pid: pid} do
      stub(Loomkin.MockAdapter, :send_text, fn _b, _t, _o -> {:error, :network_error} end)

      send_signal(pid, "agent.error", %{agent_name: "agent", error: "err"})
      Process.sleep(50)

      state = :sys.get_state(pid)
      {count, _} = state.rate_limiter
      assert count == 1
    end
  end
end
