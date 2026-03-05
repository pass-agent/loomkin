defmodule Loomkin.Channels.SeverityTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Severity

  describe "classify/1" do
    test "ask_user_question is urgent" do
      assert :urgent = Severity.classify({:ask_user_question, %{}})
    end

    test "agent_error is urgent" do
      assert :urgent = Severity.classify({:agent_error, %{}})
    end

    test "team_dissolved is urgent" do
      assert :urgent = Severity.classify(:team_dissolved)
    end

    test "permission_request is urgent" do
      assert :urgent =
               Severity.classify({:permission_request, "t", "tool", "/p", {:agent, "t", "a"}})
    end

    test "new_message is action" do
      assert :action = Severity.classify({:new_message, %{}})
    end

    test "conflict_detected collab_event is action" do
      assert :action = Severity.classify({:collab_event, %{type: :conflict_detected}})
    end

    test "consensus_reached collab_event is action" do
      assert :action = Severity.classify({:collab_event, %{type: :consensus_reached}})
    end

    test "task_completed collab_event is action" do
      assert :action = Severity.classify({:collab_event, %{type: :task_completed}})
    end

    test "other collab_events are info" do
      assert :info = Severity.classify({:collab_event, %{type: :discovery_shared}})
      assert :info = Severity.classify({:collab_event, %{type: :question_asked}})
    end

    test "context_update is info" do
      assert :info = Severity.classify({:context_update, %{}})
    end

    test "channel_message is info" do
      assert :info = Severity.classify({:channel_message, %{}})
    end

    # Session events
    test "session_cancelled is urgent" do
      assert :urgent = Severity.classify({:session_cancelled, "sess-1"})
    end

    test "llm_error is urgent" do
      assert :urgent = Severity.classify({:llm_error, "sess-1", "timeout"})
    end

    test "session_status is info" do
      assert :info = Severity.classify({:session_status, "sess-1", :running})
    end

    test "team_available is info" do
      assert :info = Severity.classify({:team_available, "sess-1", "team-1"})
    end

    test "child_team_available is info" do
      assert :info = Severity.classify({:child_team_available, "sess-1", "child-1"})
    end

    test "3-arity new_message (session) is action" do
      assert :action = Severity.classify({:new_message, "sess-1", %{}})
    end

    test "stream_start is noise" do
      assert :noise = Severity.classify({:stream_start, "sess-1"})
    end

    test "stream_end is noise" do
      assert :noise = Severity.classify({:stream_end, "sess-1"})
    end

    # Telemetry events
    test "team_budget_warning is urgent" do
      assert :urgent = Severity.classify({:team_budget_warning, %{spent: 5.0, limit: 10.0}})
    end

    test "team_escalation is action" do
      assert :action = Severity.classify({:team_escalation, %{agent_name: "coder"}})
    end

    test "team_llm_stop is info" do
      assert :info = Severity.classify({:team_llm_stop, %{cost: 0.01}})
    end

    test "stream_delta is noise" do
      assert :noise = Severity.classify({:stream_delta, %{}})
    end

    test "3-arity stream_delta (session) is noise" do
      assert :noise = Severity.classify({:stream_delta, "sess-1", %{text: "hi"}})
    end

    test "tool_executing is noise" do
      assert :noise = Severity.classify({:tool_executing, %{}})
    end

    test "usage is noise" do
      assert :noise = Severity.classify({:usage, %{}})
    end

    test "unknown events default to info" do
      assert :info = Severity.classify({:something_else, %{}})
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
