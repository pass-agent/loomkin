defmodule LoomkinWeb.Live.WorkspaceBroadcastTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  describe "message routing" do
    test "selecting 'team' clears reply_target (routes to concierge)" do
      socket = build_test_socket(reply_target: %{agent: "coder", team_id: "team-123"})

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:composer_event, "select_reply_target", %{"agent" => "team"}},
          socket
        )

      assert updated_socket.assigns.reply_target == nil
    end

    test "selecting specific agent sets reply_target" do
      socket = build_test_socket()

      {:noreply, updated_socket} =
        WorkspaceLive.handle_info(
          {:composer_event, "select_reply_target",
           %{"agent" => "researcher-agent", "team-id" => "team-123"}},
          socket
        )

      assert updated_socket.assigns.reply_target == %{
               agent: "researcher-agent",
               team_id: "team-123"
             }
    end
  end

  # Build a minimal Phoenix.LiveView.Socket with message-routing assigns.
  defp build_test_socket(opts \\ []) do
    reply_target = Keyword.get(opts, :reply_target, nil)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
        flash: %{},
        live_action: :show,
        team_id: "team-123",
        reply_target: reply_target
      },
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        assign_new: {%{}, []}
      }
    }

    Phoenix.LiveView.stream(socket, :comms_events, [])
  end
end
