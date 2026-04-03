defmodule LoomkinWeb.Live.WorkspaceLiveApprovalTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  # ---------------------------------------------------------------------------
  # Task 1: approve_card_agent and deny_card_agent handle_event
  # ---------------------------------------------------------------------------

  describe "approve_card_agent event" do
    test "routes approval response to blocking tool task via Registry" do
      gate_id = "gate-001"
      agent_name = "worker-agent"

      # Register this test process as the "tool task" in the AgentRegistry
      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _updated_socket} =
        WorkspaceLive.handle_event(
          "approve_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "context" => "looks good"},
          socket
        )

      # The handler must send {:approval_response, gate_id, decision} to the registered pid
      assert_receive {:approval_response, ^gate_id, %{outcome: :approved, context: "looks good"}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "normalizes empty context string to nil" do
      gate_id = "gate-002"
      agent_name = "worker-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "approve_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "context" => ""},
          socket
        )

      assert_receive {:approval_response, ^gate_id, %{outcome: :approved, context: nil}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "clears pending_approval from agent card assigns" do
      gate_id = "gate-003"
      agent_name = "worker-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_event(
          "approve_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "context" => nil},
          socket
        )

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert is_nil(card[:pending_approval])

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "returns noreply when no registered pid for gate_id" do
      socket = build_test_socket(agent_name: "ghost-agent", gate_id: nil)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "approve_card_agent",
          %{"gate_id" => "nonexistent-gate", "agent" => "ghost-agent", "context" => ""},
          socket
        )
    end
  end

  describe "deny_card_agent event" do
    test "routes denial with reason to tool task via Registry" do
      gate_id = "gate-deny-001"
      agent_name = "worker-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "deny_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "reason" => "not safe"},
          socket
        )

      assert_receive {:approval_response, ^gate_id,
                      %{outcome: :denied, reason: "not safe", context: nil}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "normalizes empty reason string to nil" do
      gate_id = "gate-deny-002"
      agent_name = "worker-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "deny_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "reason" => ""},
          socket
        )

      assert_receive {:approval_response, ^gate_id, %{outcome: :denied, reason: nil}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "clears pending_approval from agent card assigns" do
      gate_id = "gate-deny-003"
      agent_name = "worker-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_event(
          "deny_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "reason" => "not ready"},
          socket
        )

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert is_nil(card[:pending_approval])

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end

    test "clears leader_approval_pending assign when gate_id matches" do
      gate_id = "gate-deny-lead-001"
      agent_name = "lead-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, %{})

      started_at = System.monotonic_time(:millisecond)

      socket =
        build_test_socket(
          agent_name: agent_name,
          gate_id: gate_id,
          leader_approval_pending: %{
            gate_id: gate_id,
            timeout_ms: 300_000,
            started_at: started_at
          }
        )

      {:noreply, updated_socket} =
        WorkspaceLive.handle_event(
          "deny_card_agent",
          %{"gate_id" => gate_id, "agent" => agent_name, "reason" => "risky"},
          socket
        )

      assert is_nil(updated_socket.assigns.leader_approval_pending)

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
    end
  end

  # ---------------------------------------------------------------------------
  # Task 2: handle_info for ApprovalRequested/Resolved, leader banner, comms
  # ---------------------------------------------------------------------------

  describe "leader approval banner" do
    test "leader_approval_pending assign is set when ApprovalRequested signal arrives for lead agent" do
      gate_id = "gate-lead-001"
      agent_name = "lead-agent"

      signal = approval_requested_signal(gate_id, agent_name, "Should I proceed?", 300_000)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil, agent_role: :lead)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert %{gate_id: ^gate_id, timeout_ms: 300_000, started_at: _} =
               updated_socket.assigns.leader_approval_pending
    end

    test "leader_approval_pending is NOT set for non-lead agent" do
      gate_id = "gate-peer-001"
      agent_name = "peer-agent"

      signal = approval_requested_signal(gate_id, agent_name, "Should I delete?", 300_000)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil, agent_role: :peer)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert is_nil(updated_socket.assigns.leader_approval_pending)
    end

    test "ApprovalRequested sets pending_approval on agent card" do
      gate_id = "gate-card-001"
      agent_name = "worker-agent"
      question = "Can I write to /etc/hosts?"

      signal = approval_requested_signal(gate_id, agent_name, question, 300_000)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert %{gate_id: ^gate_id, question: ^question} = card.pending_approval
    end

    test "ApprovalRequested does not push comms event (routed to signals)" do
      gate_id = "gate-comms-001"
      agent_name = "worker-agent"

      signal = approval_requested_signal(gate_id, agent_name, "Proceed?", 300_000)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 0
    end

    test "leader_approval_pending assign is cleared when ApprovalResolved signal arrives" do
      gate_id = "gate-resolved-001"
      agent_name = "lead-agent"

      signal = approval_resolved_signal(gate_id, agent_name, :approved)

      started_at = System.monotonic_time(:millisecond)

      socket =
        build_test_socket(
          agent_name: agent_name,
          gate_id: gate_id,
          agent_role: :lead,
          leader_approval_pending: %{
            gate_id: gate_id,
            timeout_ms: 300_000,
            started_at: started_at
          }
        )

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert is_nil(updated_socket.assigns.leader_approval_pending)
    end

    test "ApprovalResolved clears pending_approval from agent card" do
      gate_id = "gate-resolved-002"
      agent_name = "worker-agent"

      signal = approval_resolved_signal(gate_id, agent_name, :denied)

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert is_nil(card[:pending_approval])
    end

    test "ApprovalResolved does not push comms event (routed to signals)" do
      gate_id = "gate-resolved-comms-001"
      agent_name = "worker-agent"

      signal = approval_resolved_signal(gate_id, agent_name, :timeout)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp approval_requested_signal(gate_id, agent_name, question, timeout_ms) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: "agent.approval.requested",
      source: "/test/approval",
      data: %{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: "team-test",
        question: question,
        timeout_ms: timeout_ms
      },
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  defp approval_resolved_signal(gate_id, agent_name, outcome) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: "agent.approval.resolved",
      source: "/test/approval",
      data: %{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: "team-test",
        outcome: outcome
      },
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  # Build a minimal Phoenix.LiveView.Socket with approval-relevant assigns.
  # All state is embedded in the assigns map directly (no post-construction assign calls).
  defp build_test_socket(opts) do
    agent_name = Keyword.get(opts, :agent_name, "test-agent")
    gate_id = Keyword.get(opts, :gate_id)
    agent_role = Keyword.get(opts, :agent_role, :peer)
    leader_approval_pending = Keyword.get(opts, :leader_approval_pending, nil)

    pending_approval =
      if gate_id do
        %{
          gate_id: gate_id,
          question: "proceed?",
          timeout_ms: 300_000,
          started_at: System.monotonic_time(:millisecond)
        }
      end

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
        flash: %{},
        live_action: :show,
        team_id: "team-test",
        active_team_id: "team-test",
        leader_approval_pending: leader_approval_pending,
        cached_agents: [],
        agent_cards: %{
          agent_name => %{
            name: agent_name,
            role: agent_role,
            status: :working,
            pending_approval: pending_approval
          }
        }
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
