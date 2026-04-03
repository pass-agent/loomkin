defmodule Loomkin.Channels.SeverityTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Severity

  defp signal(type, data \\ %{}) do
    %Jido.Signal{
      id: Ecto.UUID.generate(),
      type: type,
      data: data,
      source: "test",
      specversion: "1.0.2",
      datacontenttype: "application/json"
    }
  end

  describe "classify/1" do
    test "ask_user_question is urgent" do
      assert :urgent = Severity.classify(signal("team.ask_user.question"))
    end

    test "agent_error is urgent" do
      assert :urgent = Severity.classify(signal("agent.error"))
    end

    test "team_dissolved is urgent" do
      assert :urgent = Severity.classify(signal("team.dissolved"))
    end

    test "permission_request is urgent" do
      assert :urgent = Severity.classify(signal("team.permission.request"))
    end

    test "new_message is action" do
      assert :action = Severity.classify(signal("session.message.new"))
    end

    test "conflict_detected collab_event is action" do
      assert :action = Severity.classify(signal("team.conflict.detected"))
    end

    test "consensus_reached collab_event is action" do
      # Collab events wrapped in collaboration signals are info
      assert :info = Severity.classify(signal("collaboration.peer.message"))
    end

    test "task_completed collab_event is action" do
      # task_completed goes through team.task.completed signal
      assert :info = Severity.classify(signal("collaboration.peer.message"))
    end

    test "other collab_events are info" do
      assert :info = Severity.classify(signal("collaboration.peer.message"))
    end

    test "context_update is info" do
      assert :info = Severity.classify(signal("context.update"))
    end

    test "channel_message is info" do
      assert :info = Severity.classify(signal("channel.message"))
    end

    # Session events
    test "session_cancelled is urgent" do
      assert :urgent = Severity.classify(signal("session.cancelled"))
    end

    test "llm_error is urgent" do
      assert :urgent = Severity.classify(signal("session.llm.error"))
    end

    test "session_status is info" do
      assert :info = Severity.classify(signal("session.status.changed"))
    end

    test "team_available is info" do
      assert :info = Severity.classify(signal("session.team.available"))
    end

    test "child_team_available is info" do
      assert :info = Severity.classify(signal("session.child_team.available"))
    end

    test "3-arity new_message (session) is action" do
      assert :action = Severity.classify(signal("session.message.new"))
    end

    test "stream_start is noise" do
      assert :noise = Severity.classify(signal("agent.stream.start"))
    end

    test "stream_end is noise" do
      assert :noise = Severity.classify(signal("agent.stream.end"))
    end

    # Telemetry events
    test "team_budget_warning is urgent" do
      assert :urgent = Severity.classify(signal("team.budget.warning"))
    end

    test "team_escalation is action" do
      assert :action = Severity.classify(signal("agent.escalation"))
    end

    test "team_llm_stop is info" do
      assert :info = Severity.classify(signal("team.llm.stop"))
    end

    test "stream_delta is noise" do
      assert :noise = Severity.classify(signal("agent.stream.delta"))
    end

    test "3-arity stream_delta (session) is noise" do
      assert :noise = Severity.classify(signal("agent.stream.delta"))
    end

    test "tool_executing is noise" do
      assert :noise = Severity.classify(signal("agent.tool.executing"))
    end

    test "usage is noise" do
      assert :noise = Severity.classify(signal("agent.usage"))
    end

    test "unknown events default to info" do
      assert :info = Severity.classify(signal("something.else"))
      assert :info = Severity.classify("random")
    end
  end

  describe "notify?/2" do
    test "noise is never forwarded" do
      refute Severity.notify?(:noise, ["urgent", "action", "info", "noise"])
    end

    test "urgent is forwarded when in levels" do
      assert Severity.notify?(:urgent, ["urgent", "action"])
    end

    test "action is forwarded when in levels" do
      assert Severity.notify?(:action, ["urgent", "action"])
    end

    test "info is not forwarded by default levels" do
      refute Severity.notify?(:info, Severity.default_levels())
    end

    test "info is forwarded when explicitly included" do
      assert Severity.notify?(:info, ["urgent", "action", "info"])
    end

    test "works with atom levels" do
      assert Severity.notify?(:urgent, [:urgent, :action])
    end
  end

  describe "default_levels/0" do
    test "returns urgent and action" do
      assert Severity.default_levels() == ["urgent", "action"]
    end
  end
end
