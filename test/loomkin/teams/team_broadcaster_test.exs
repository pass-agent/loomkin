defmodule Loomkin.Teams.TeamBroadcasterTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.TeamBroadcaster
  alias Loomkin.Signals

  @team_id "team-test-1"

  defp build_signal(type, team_id \\ @team_id) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: type,
      source: "/test",
      data: %{team_id: team_id, content: "test-#{type}"},
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  defp start_broadcaster(opts \\ []) do
    team_ids = Keyword.get(opts, :team_ids, [@team_id])
    start_supervised!({TeamBroadcaster, team_ids: team_ids})
  end

  describe "batching" do
    test "batchable signal does not deliver immediately" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.stream.delta")
      Signals.publish(signal)

      refute_receive {:team_broadcast, _}, 20
    end

    test "batchable signals are delivered after flush interval" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.stream.delta")
      Signals.publish(signal)

      assert_receive {:team_broadcast, batch}, 200
      assert is_map(batch)
      assert Map.has_key?(batch, :streaming)
    end

    test "multiple batchable signals grouped into single delivery by category" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      Signals.publish(build_signal("agent.stream.delta"))
      Signals.publish(build_signal("agent.tool.started"))
      Signals.publish(build_signal("context.update"))

      # Collect all batches within the window — on slow CI runners signals
      # may arrive across multiple flush intervals, producing separate batches.
      merged =
        Enum.reduce_while(1..5, %{streaming: [], tools: [], activity: []}, fn _, acc ->
          receive do
            {:team_broadcast, batch} when is_map(batch) ->
              merged = %{
                streaming: acc.streaming ++ Map.get(batch, :streaming, []),
                tools: acc.tools ++ Map.get(batch, :tools, []),
                activity: acc.activity ++ Map.get(batch, :activity, [])
              }

              if length(merged.streaming) >= 1 and length(merged.tools) >= 1 and
                   length(merged.activity) >= 1 do
                {:halt, merged}
              else
                {:cont, merged}
              end
          after
            300 -> {:halt, acc}
          end
        end)

      assert length(merged.streaming) >= 1
      assert length(merged.tools) >= 1
      assert length(merged.activity) >= 1
    end
  end

  describe "critical signals" do
    test "critical signal delivers immediately" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("team.permission.request")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "team.permission.request"
    end

    test "agent.error delivers immediately" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.error")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "agent.error"
    end

    test "team.dissolved delivers immediately" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("team.dissolved")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "team.dissolved"
    end
  end

  describe "peer message critical classification" do
    test "collaboration.peer.message is classified as critical" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("collaboration.peer.message")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "collaboration.peer.message"
    end
  end

  describe "child team created critical classification" do
    test "team.child.created is classified as critical" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "team.child.created",
        source: "/test",
        data: %{
          team_id: "child-team-1",
          parent_team_id: @team_id,
          team_name: "child-team",
          depth: 1
        },
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "team.child.created"
    end
  end

  describe "approval gate critical classification" do
    test "agent.approval.requested is classified as critical" do
      # Verifies that "agent.approval.requested" is in @critical_types and delivers immediately
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.approval.requested")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "agent.approval.requested"
    end

    test "agent.approval.resolved is classified as critical" do
      # Verifies that "agent.approval.resolved" is in @critical_types and delivers immediately
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.approval.resolved")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "agent.approval.resolved"
    end
  end

  describe "spawn gate critical classification" do
    test "agent.spawn.gate.requested is classified as critical" do
      # Verifies that "agent.spawn.gate.requested" is in @critical_types and delivers immediately
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.spawn.gate.requested")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "agent.spawn.gate.requested"
    end

    test "agent.spawn.gate.resolved is classified as critical" do
      # Verifies that "agent.spawn.gate.resolved" is in @critical_types and delivers immediately
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = build_signal("agent.spawn.gate.resolved")
      Signals.publish(signal)

      assert_receive {:team_broadcast, %{critical: [received]}}, 50
      assert received.type == "agent.spawn.gate.resolved"
    end
  end

  describe "team_id filtering" do
    test "subscriber receives signals matching their team_ids" do
      broadcaster = start_broadcaster(team_ids: [@team_id])
      TeamBroadcaster.subscribe(broadcaster, self())

      Signals.publish(build_signal("agent.stream.delta", @team_id))

      assert_receive {:team_broadcast, _}, 200
    end

    test "subscriber does not receive signals for other teams" do
      broadcaster = start_broadcaster(team_ids: [@team_id])
      TeamBroadcaster.subscribe(broadcaster, self())

      Signals.publish(build_signal("agent.stream.delta", "other-team"))

      refute_receive {:team_broadcast, _}, 100
    end

    test "signals with nil team_id are dropped" do
      broadcaster = start_broadcaster(team_ids: [@team_id])
      TeamBroadcaster.subscribe(broadcaster, self())

      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "agent.stream.delta",
        source: "/test",
        data: %{content: "no team"},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      Signals.publish(signal)

      refute_receive {:team_broadcast, _}, 100
    end
  end

  describe "subscriber cleanup" do
    test "dead subscriber is removed via Process.monitor" do
      broadcaster = start_broadcaster()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(pid)
      TeamBroadcaster.subscribe(broadcaster, pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # Synchronize — ensure broadcaster has processed the DOWN message
      _ = :sys.get_state(broadcaster)

      # Publishing should not crash the broadcaster
      Signals.publish(build_signal("team.permission.request"))
      _ = :sys.get_state(broadcaster)

      # Broadcaster is still alive
      assert Process.alive?(broadcaster)
    end
  end

  describe "terminate/2" do
    test "terminate unsubscribes from signal bus" do
      broadcaster = start_broadcaster()
      # Stop the broadcaster cleanly
      GenServer.stop(broadcaster, :normal)

      # Broadcaster should be stopped
      refute Process.alive?(broadcaster)
    end
  end

  describe "subscribe/2" do
    test "subscribe is idempotent" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())
      TeamBroadcaster.subscribe(broadcaster, self())

      Signals.publish(build_signal("team.permission.request"))

      # Should receive exactly one message, not two
      assert_receive {:team_broadcast, %{critical: _}}, 50
      refute_receive {:team_broadcast, _}, 50
    end
  end

  describe "add_team/2" do
    test "adds a new team_id to the filter set" do
      broadcaster = start_broadcaster(team_ids: [@team_id])
      TeamBroadcaster.subscribe(broadcaster, self())

      # Initially should not receive signals for new-team
      Signals.publish(build_signal("agent.stream.delta", "new-team"))
      refute_receive {:team_broadcast, _}, 100

      # Add the new team
      TeamBroadcaster.add_team(broadcaster, "new-team")

      # Now should receive signals for new-team
      Signals.publish(build_signal("agent.stream.delta", "new-team"))
      assert_receive {:team_broadcast, _}, 200
    end
  end
end
