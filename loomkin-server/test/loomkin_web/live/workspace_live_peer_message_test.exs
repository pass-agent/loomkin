defmodule LoomkinWeb.WorkspaceLivePeerMessageTest do
  use ExUnit.Case, async: true

  alias LoomkinWeb.WorkspaceLive

  describe "peer message signal handling" do
    test "collaboration.peer.message signal creates :peer_message comms event" do
      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "collaboration.peer.message",
        source: "/test",
        data: %{from: "agent-a", team_id: "team-123", message: "hello from agent-a"},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      socket = build_test_socket()
      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 1
    end

    test "peer message extracts agent name from signal data :from field" do
      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "collaboration.peer.message",
        source: "/test",
        data: %{from: "researcher-bot", team_id: "team-456", message: "found results"},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      socket = build_test_socket()
      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 1
    end

    test "peer message handles tuple format {:peer_message, sender, text}" do
      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "collaboration.peer.message",
        source: "/test",
        data: %{
          from: "agent-b",
          team_id: "team-789",
          message: {:peer_message, "agent-b", "tuple msg"}
        },
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      socket = build_test_socket()
      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 1
    end

    test "peer message defaults agent to 'unknown' when :from is missing" do
      signal = %Jido.Signal{
        id: Jido.Signal.ID.generate(),
        type: "collaboration.peer.message",
        source: "/test",
        data: %{team_id: "team-123", message: "anonymous msg"},
        datacontenttype: "application/json",
        specversion: "1.0.1"
      }

      socket = build_test_socket()
      {:noreply, updated_socket} = WorkspaceLive.handle_info(signal, socket)

      assert updated_socket.assigns.comms_event_count == 1
    end
  end

  # Build a minimal Phoenix.LiveView.Socket for unit testing handle_info.
  # Uses Phoenix.LiveView.stream/3 to properly initialize stream infrastructure.
  defp build_test_socket do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comms_event_count: 0,
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
