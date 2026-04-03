defmodule LoomkinWeb.Live.WorkspaceLiveSpawnGateTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  # ---------------------------------------------------------------------------
  # approve_spawn event
  # ---------------------------------------------------------------------------

  describe "approve_spawn event" do
    test "routes {:spawn_gate_response, gate_id, %{outcome: :approved}} to Registry-registered blocking process" do
      gate_id = "spawn-gate-001"
      agent_name = "leader-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _updated_socket} =
        WorkspaceLive.handle_event(
          "approve_spawn",
          %{"gate_id" => gate_id, "agent" => agent_name, "context" => "looks good"},
          socket
        )

      assert_receive {:spawn_gate_response, ^gate_id, %{outcome: :approved}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id})
    end

    test "returns noreply when no registered pid for gate_id" do
      socket = build_test_socket(agent_name: "ghost-agent", gate_id: nil)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "approve_spawn",
          %{"gate_id" => "nonexistent-gate", "agent" => "ghost-agent", "context" => ""},
          socket
        )
    end
  end

  # ---------------------------------------------------------------------------
  # deny_spawn event
  # ---------------------------------------------------------------------------

  describe "deny_spawn event" do
    test "routes {:spawn_gate_response, gate_id, %{outcome: :denied, reason: reason}} to Registry-registered blocking process" do
      gate_id = "spawn-gate-deny-001"
      agent_name = "leader-agent"

      {:ok, _} =
        Registry.register(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id}, %{})

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "deny_spawn",
          %{"gate_id" => gate_id, "agent" => agent_name, "reason" => "too expensive"},
          socket
        )

      assert_receive {:spawn_gate_response, ^gate_id,
                      %{outcome: :denied, reason: "too expensive"}}

      Registry.unregister(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id})
    end

    test "returns noreply when no registered pid for gate_id" do
      socket = build_test_socket(agent_name: "ghost-agent", gate_id: nil)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "deny_spawn",
          %{"gate_id" => "nonexistent-gate", "agent" => "ghost-agent", "reason" => ""},
          socket
        )
    end
  end

  # ---------------------------------------------------------------------------
  # toggle_auto_approve_spawns event
  # ---------------------------------------------------------------------------

  describe "toggle_auto_approve_spawns event" do
    test "calls set_auto_approve_spawns on agent GenServer when enabled is \"true\"" do
      # This test verifies the handler does not crash when no agent pid is found
      # (the agent is not running in unit tests); it should noreply gracefully.
      socket = build_test_socket(agent_name: "leader-agent", gate_id: nil)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "toggle_auto_approve_spawns",
          %{"agent" => "leader-agent", "enabled" => "true"},
          socket
        )
    end

    test "returns noreply even when enabled is \"false\"" do
      socket = build_test_socket(agent_name: "leader-agent", gate_id: nil)

      {:noreply, _} =
        WorkspaceLive.handle_event(
          "toggle_auto_approve_spawns",
          %{"agent" => "leader-agent", "enabled" => "false"},
          socket
        )
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: SpawnGateRequested signal
  # ---------------------------------------------------------------------------

  describe "handle_info SpawnGateRequested" do
    test "sets pending_approval on the matching agent card" do
      gate_id = "spawn-gate-req-001"
      agent_name = "leader-agent"

      signal = spawn_gate_requested_signal(gate_id, agent_name)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert %{type: :spawn_gate, gate_id: ^gate_id} = card.pending_approval
    end

    test "pending_approval map includes team_name, roles, estimated_cost, timeout_ms, started_at" do
      gate_id = "spawn-gate-req-002"
      agent_name = "leader-agent"

      signal = spawn_gate_requested_signal(gate_id, agent_name)

      socket = build_test_socket(agent_name: agent_name, gate_id: nil)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      pa = card.pending_approval

      assert pa.type == :spawn_gate
      assert pa.team_name == "research-team"
      assert is_list(pa.roles)
      assert is_float(pa.estimated_cost)
      assert pa.timeout_ms == 300_000
      assert is_integer(pa.started_at)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: SpawnGateResolved signal
  # ---------------------------------------------------------------------------

  describe "handle_info SpawnGateResolved" do
    test "clears pending_approval from the matching agent card" do
      gate_id = "spawn-gate-res-001"
      agent_name = "leader-agent"

      signal = spawn_gate_resolved_signal(gate_id, agent_name, :approved)

      socket = build_test_socket(agent_name: agent_name, gate_id: gate_id)

      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      card = get_in(updated_socket.assigns, [:agent_cards, agent_name])
      assert is_nil(card[:pending_approval])
    end

    test "returns noreply gracefully when agent card does not exist" do
      gate_id = "spawn-gate-res-002"
      agent_name = "unknown-agent"

      signal = spawn_gate_resolved_signal(gate_id, agent_name, :denied)

      socket = build_test_socket(agent_name: "other-agent", gate_id: nil)

      {:noreply, _updated_socket} = WorkspaceLive.handle_info(signal, socket)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: spawn gate comms feed events
  # ---------------------------------------------------------------------------

  describe "spawn gate signals do not insert comms events (routed to signals)" do
    test "SpawnGateRequested does not insert comms event" do
      socket = build_test_socket(agent_name: "leader", gate_id: nil)

      sig = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "agent.spawn.gate.requested",
        source: "/test/spawn",
        data: %{
          gate_id: "gate-comms-1",
          agent_name: "leader",
          team_name: "research-team",
          roles: %{researcher: 2},
          estimated_cost: 0.05
        },
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      {:noreply, updated_socket} = WorkspaceLive.handle_info(sig, socket)

      assert updated_socket.assigns.comms_event_count == socket.assigns.comms_event_count
    end

    test "SpawnGateResolved does not insert comms event" do
      socket = build_test_socket(agent_name: "leader", gate_id: "gate-comms-2")

      sig = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "agent.spawn.gate.resolved",
        source: "/test/spawn",
        data: %{agent_name: "leader", outcome: :approved},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      {:noreply, updated_socket} = WorkspaceLive.handle_info(sig, socket)

      assert updated_socket.assigns.comms_event_count == socket.assigns.comms_event_count
    end

    test "SpawnGateResolved with denied outcome does not insert comms event" do
      socket = build_test_socket(agent_name: "leader", gate_id: "gate-comms-3")

      sig = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "agent.spawn.gate.resolved",
        source: "/test/spawn",
        data: %{agent_name: "leader", outcome: :denied},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      {:noreply, updated_socket} = WorkspaceLive.handle_info(sig, socket)

      assert updated_socket.assigns.comms_event_count == socket.assigns.comms_event_count
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_gate_requested_signal(gate_id, agent_name) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: "agent.spawn.gate.requested",
      source: "/test/spawn",
      data: %{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: "team-test",
        team_name: "research-team",
        roles: [%{"role" => "researcher"}, %{"role" => "coder"}],
        estimated_cost: 0.70,
        limit_warning: nil,
        timeout_ms: 300_000,
        auto_approve_spawns: false
      },
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  defp spawn_gate_resolved_signal(gate_id, agent_name, outcome) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: "agent.spawn.gate.resolved",
      source: "/test/spawn",
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

  # Build a minimal Phoenix.LiveView.Socket with spawn-gate-relevant assigns.
  defp build_test_socket(opts) do
    agent_name = Keyword.get(opts, :agent_name, "test-agent")
    gate_id = Keyword.get(opts, :gate_id)

    pending_approval =
      if gate_id do
        %{
          type: :spawn_gate,
          gate_id: gate_id,
          team_name: "test-team",
          roles: [],
          estimated_cost: 0.50,
          limit_warning: nil,
          timeout_ms: 300_000,
          started_at: System.monotonic_time(:millisecond),
          auto_approve_spawns: false
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
        leader_approval_pending: nil,
        cached_agents: [],
        agent_cards: %{
          agent_name => %{
            name: agent_name,
            role: :peer,
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
