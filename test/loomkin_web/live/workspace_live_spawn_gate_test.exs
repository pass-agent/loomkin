defmodule LoomkinWeb.Live.WorkspaceLiveSpawnGateTest do
  use ExUnit.Case, async: true

  # Wave 0 stub pattern — all tests skipped until Plans 02-03 implement spawn gate
  @moduletag :skip

  # alias LoomkinWeb.WorkspaceLive

  # ---------------------------------------------------------------------------
  # approve_spawn event
  # ---------------------------------------------------------------------------

  describe "approve_spawn event" do
    @tag :skip
    test "routes {:spawn_gate_response, gate_id, %{outcome: :approved}} to Registry-registered blocking process" do
      # Pattern: spawn process registered under {:spawn_gate, gate_id} in Loomkin.Teams.AgentRegistry,
      # simulate handle_event("approve_spawn", %{"gate_id" => gate_id, "agent" => agent_name}, socket),
      # then assert_receive {:spawn_gate_response, gate_id, %{outcome: :approved}}
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # deny_spawn event
  # ---------------------------------------------------------------------------

  describe "deny_spawn event" do
    @tag :skip
    test "routes {:spawn_gate_response, gate_id, %{outcome: :denied, reason: reason}} to Registry-registered blocking process" do
      # Pattern: Registry.register({:spawn_gate, gate_id}), simulate deny_spawn event,
      # assert_receive {:spawn_gate_response, gate_id, %{outcome: :denied, reason: reason}}
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # toggle_auto_approve_spawns event
  # ---------------------------------------------------------------------------

  describe "toggle_auto_approve_spawns event" do
    @tag :skip
    test "calls set_auto_approve_spawns on agent GenServer when enabled is \"true\"" do
      # Pattern: start an agent, simulate toggle_auto_approve_spawns event with enabled "true",
      # verify agent GenServer state updated via :get_spawn_settings
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: SpawnGateRequested signal
  # ---------------------------------------------------------------------------

  describe "handle_info SpawnGateRequested" do
    @tag :skip
    test "sets pending_approval on the matching agent card" do
      # Pattern: send SpawnGateRequested signal to handle_info,
      # assert agent_cards[agent_name].pending_approval is set with gate_id and question
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: SpawnGateResolved signal
  # ---------------------------------------------------------------------------

  describe "handle_info SpawnGateResolved" do
    @tag :skip
    test "clears pending_approval from the matching agent card" do
      # Pattern: build socket with pending_approval set on agent card,
      # send SpawnGateResolved signal, assert pending_approval is nil
      flunk("not implemented")
    end
  end
end
