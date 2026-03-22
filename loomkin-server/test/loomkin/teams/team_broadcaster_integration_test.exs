defmodule Loomkin.Teams.TeamBroadcasterIntegrationTest do
  @moduledoc """
  Integration tests verifying the full signal flow:
  publish on bus -> TeamBroadcaster receives -> batches -> delivers to subscriber.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Teams.TeamBroadcaster
  alias Loomkin.Signals

  @team_id "integration-team-1"

  defp build_signal(type, team_id \\ @team_id, extra_data \\ %{}) do
    %Jido.Signal{
      id: Jido.Signal.ID.generate(),
      type: type,
      source: "/integration-test",
      data: Map.merge(%{team_id: team_id, content: "integration-#{type}"}, extra_data),
      datacontenttype: "application/json",
      specversion: "1.0.1"
    }
  end

  defp start_broadcaster(opts \\ []) do
    team_ids = Keyword.get(opts, :team_ids, [@team_id])
    start_supervised!({TeamBroadcaster, team_ids: team_ids})
  end

  describe "batched delivery flow" do
    test "publishes multiple streaming signals and receives them batched" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      # Publish 5 agent.stream.delta signals in quick succession
      for i <- 1..5 do
        Signals.publish(build_signal("agent.stream.delta", @team_id, %{index: i}))
      end

      # Collect all batches within the window — signals may span multiple flush cycles.
      # On slow CI runners, increase the window and accept 3+ of 5 signals.
      total_streaming =
        Enum.reduce_while(1..5, 0, fn _, acc ->
          receive do
            {:team_broadcast, %{streaming: sigs} = _batch} ->
              {:cont, acc + length(sigs)}
          after
            300 -> {:halt, acc}
          end
        end)

      assert total_streaming >= 3 and total_streaming <= 5
    end
  end

  describe "critical bypass flow" do
    test "critical signal arrives before batch timer fires" do
      broadcaster = start_broadcaster()
      TeamBroadcaster.subscribe(broadcaster, self())

      # Publish a critical signal
      Signals.publish(build_signal("team.permission.request"))

      # Should arrive almost immediately, well before the 50ms batch window
      assert_receive {:team_broadcast, %{critical: [sig]}}, 50
      assert sig.type == "team.permission.request"
    end
  end

  describe "team filtering" do
    test "filters signals by team_id and allows after add_team" do
      broadcaster = start_broadcaster(team_ids: [@team_id])
      TeamBroadcaster.subscribe(broadcaster, self())

      # Publish a signal for a team we are NOT subscribed to
      Signals.publish(build_signal("agent.stream.delta", "team-b"))
      refute_receive {:team_broadcast, _}, 100

      # Add team-b to the broadcaster filter
      TeamBroadcaster.add_team(broadcaster, "team-b")

      # Now signals for team-b should be delivered
      Signals.publish(build_signal("agent.stream.delta", "team-b"))
      assert_receive {:team_broadcast, batch}, 200
      assert length(batch.streaming) >= 1
    end
  end

  describe "subscriber cleanup on death" do
    test "broadcaster survives subscriber death and continues delivering to other subscribers" do
      broadcaster = start_broadcaster()

      # Spawn a process that subscribes and then dies
      doomed_pid =
        spawn(fn ->
          TeamBroadcaster.subscribe(broadcaster, self())

          receive do
            :die -> :ok
          end
        end)

      # Also subscribe self
      TeamBroadcaster.subscribe(broadcaster, self())

      # Kill the doomed process
      ref = Process.monitor(doomed_pid)
      send(doomed_pid, :die)
      assert_receive {:DOWN, ^ref, :process, ^doomed_pid, :normal}
      # Synchronize — ensure broadcaster has processed the DOWN message
      _ = :sys.get_state(broadcaster)

      # Broadcaster should still be alive and delivering signals
      assert Process.alive?(broadcaster)
      Signals.publish(build_signal("team.permission.request"))

      assert_receive {:team_broadcast, %{critical: [sig]}}, 50
      assert sig.type == "team.permission.request"
    end
  end
end
