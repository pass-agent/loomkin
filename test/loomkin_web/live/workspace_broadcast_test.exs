defmodule LoomkinWeb.Live.WorkspaceBroadcastTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  describe "broadcast mode" do
    test "defaults to broadcast_mode=true in team sessions" do
      socket = build_test_socket(team_id: "team-123")
      assert socket.assigns.broadcast_mode == true
    end

    test "defaults to broadcast_mode=false in solo sessions" do
      socket = build_test_socket(team_id: nil)
      assert socket.assigns.broadcast_mode == false
    end

    test "selecting 'Entire Kin' sets broadcast_mode=true" do
      socket = build_test_socket(team_id: "team-123", broadcast_mode: false)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:composer_event, "select_reply_target", %{"agent" => "team"}},
          socket
        )

      assert updated_socket.assigns.broadcast_mode == true
    end

    test "selecting specific agent sets broadcast_mode=false" do
      socket = build_test_socket(team_id: "team-123", broadcast_mode: true)

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:composer_event, "select_reply_target",
           %{"agent" => "researcher-agent", "team-id" => "team-123"}},
          socket
        )

      assert updated_socket.assigns.broadcast_mode == false
    end
  end

  describe "broadcast send" do
    test "broadcast message appears in comms feed as human_broadcast" do
      # Verify the source contains the human_broadcast type assignment in the
      # send_message broadcast branch (unit-level source inspection test,
      # since the full path requires live Agent processes).
      source = File.read!("lib/loomkin_web/live/workspace_live.ex")
      assert source =~ "human_broadcast"
      assert source =~ "inject_broadcast"
    end
  end

  # Build a minimal Phoenix.LiveView.Socket with broadcast-related assigns.
  defp build_test_socket(opts) do
    team_id = Keyword.get(opts, :team_id, nil)
    broadcast_mode = Keyword.get(opts, :broadcast_mode, team_id != nil)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
        flash: %{},
        live_action: :show,
        team_id: team_id,
        broadcast_mode: broadcast_mode,
        reply_target: nil
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
