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

      assert_receive {:team_broadcast, batch}, 200
      assert length(batch.streaming) >= 1
      assert length(batch.tools) >= 1
      assert length(batch.activity) >= 1
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

    test "signals with nil team_id are forwarded to all" do
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

      assert_receive {:team_broadcast, _}, 200
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

      TeamBroadcaster.subscribe(broadcaster, pid)
      send(pid, :stop)
      # Wait for DOWN message to be processed
      Process.sleep(50)

      # Publishing should not crash the broadcaster
      Signals.publish(build_signal("team.permission.request"))
      Process.sleep(50)

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
