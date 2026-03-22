defmodule LoomkinWeb.WorkspaceLiveHealingTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  describe "healing.session.started signal" do
    test "updates agent card to :suspended_healing with :diagnosing phase" do
      socket = build_test_socket("coder-1")

      signal =
        healing_signal("healing.session.started", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          classification: %{category: :compile_error, severity: :medium}
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.status == :suspended_healing
      assert card.healing_phase == :diagnosing
      assert card.healing_error_category == "compile_error"
      assert updated.assigns.comms_event_count == 0
    end
  end

  describe "healing.diagnosis.complete signal" do
    test "transitions healing phase to :fixing and emits comms event" do
      socket = build_test_socket("coder-1")
      socket = put_in(socket.assigns.agent_cards["coder-1"].healing_phase, :diagnosing)

      signal =
        healing_signal("healing.diagnosis.complete", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          root_cause: "missing import",
          confidence: 0.85
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.healing_phase == :fixing
      assert updated.assigns.comms_event_count == 0
    end
  end

  describe "healing.fix.applied signal" do
    test "transitions healing phase to :confirming and emits comms event" do
      socket = build_test_socket("coder-1")
      socket = put_in(socket.assigns.agent_cards["coder-1"].healing_phase, :fixing)

      signal =
        healing_signal("healing.fix.applied", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          files_changed: ["lib/my_module.ex"]
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.healing_phase == :confirming
      assert updated.assigns.comms_event_count == 0
    end
  end

  describe "healing.session.complete signal" do
    test "clears healing state on :healed outcome" do
      socket = build_test_socket("coder-1")
      socket = put_in(socket.assigns.agent_cards["coder-1"].status, :suspended_healing)
      socket = put_in(socket.assigns.agent_cards["coder-1"].healing_phase, :confirming)

      signal =
        healing_signal("healing.session.complete", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :healed,
          duration_ms: 12_000
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.healing_phase == nil
      assert card.healing_error_category == nil
      assert updated.assigns.comms_event_count == 0
    end

    test "clears healing state on :escalated outcome" do
      socket = build_test_socket("coder-1")
      socket = put_in(socket.assigns.agent_cards["coder-1"].status, :suspended_healing)

      signal =
        healing_signal("healing.session.complete", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :escalated,
          duration_ms: 300_000
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.healing_phase == nil
      assert updated.assigns.comms_event_count == 0
    end

    test "clears healing state on :timed_out outcome" do
      socket = build_test_socket("coder-1")
      socket = put_in(socket.assigns.agent_cards["coder-1"].status, :suspended_healing)

      signal =
        healing_signal("healing.session.complete", %{
          session_id: "sess-123",
          team_id: "team-abc",
          agent_name: "coder-1",
          outcome: :timed_out,
          duration_ms: 300_000
        })

      {:noreply, updated} = WorkspaceLive.handle_info(signal, socket)

      card = updated.assigns.agent_cards["coder-1"]
      assert card.healing_phase == nil
      assert updated.assigns.comms_event_count == 0
    end
  end

  # --- Test helpers ---

  defp healing_signal(type, data) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: type,
      source: "/test",
      data: data,
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  defp build_test_socket(agent_name) do
    card = %{
      name: agent_name,
      status: :idle,
      role: :coder,
      content_type: nil,
      latest_content: nil,
      last_tool: nil,
      current_task: nil,
      healing_phase: nil,
      healing_error_category: nil,
      team_id: "team-abc"
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
        agent_cards: %{agent_name => card},
        cached_agents: [%{name: agent_name, role: :coder, team_id: "team-abc"}],
        active_team_id: "team-abc",
        flash: %{},
        live_action: :show
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
