defmodule Loomkin.Relay.Server.DaemonChannelTest do
  use Loomkin.DataCase, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: []

  alias Loomkin.Relay.Macaroon
  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Relay.Server.Registry
  alias Loomkin.Relay.Server.Socket

  @endpoint LoomkinWeb.Endpoint

  @workspace_id "ws-test-1"

  setup do
    # Clean registry for each test
    existing = :ets.tab2list(:loomkin_relay_registry)

    on_exit(fn ->
      :ets.delete_all_objects(:loomkin_relay_registry)

      for entry <- existing do
        :ets.insert(:loomkin_relay_registry, entry)
      end
    end)

    :ets.delete_all_objects(:loomkin_relay_registry)

    # Create a real user for realistic user_ids
    user = Loomkin.AccountsFixtures.user_fixture()

    {:ok, user: user}
  end

  defp connect_socket(user_id, workspace_id, opts \\ []) do
    token = Macaroon.mint_daemon_token(user_id, workspace_id, opts)
    connect(Socket, %{"token" => token})
  end

  defp register_payload(workspace_id \\ @workspace_id) do
    %{
      "machine_name" => "test-machine",
      "version" => "0.1.0",
      "workspaces" => [
        %{
          "id" => workspace_id,
          "name" => "loomkin",
          "project_path" => "/home/user/loomkin",
          "team_id" => nil,
          "status" => "active",
          "agent_count" => 2
        }
      ]
    }
  end

  # --- Socket authentication ---

  describe "socket authentication" do
    test "rejects connection with no token" do
      assert :error = connect(Socket, %{})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(Socket, %{"token" => "invalid-garbage-token"})
    end

    test "rejects connection with expired token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id, ttl: -1)
      assert :error = connect(Socket, %{"token" => token})
    end

    test "accepts connection with valid token and assigns claims", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "collaborator")

      assert socket.assigns.user_id == user.id
      assert socket.assigns.workspace_id == @workspace_id
      assert socket.assigns.role == "collaborator"
    end

    test "accepts owner role by default", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id)

      assert socket.assigns.role == "owner"
    end

    test "socket id includes user_id for disconnect targeting", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id)

      assert socket.id == "daemon_socket:#{user.id}"
    end
  end

  # --- Channel join authorization ---

  describe "channel join authorization" do
    test "allows join when topic matches token workspace_id", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      assert {:ok, _reply, _socket} =
               join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())
    end

    test "rejects join to wrong workspace", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      assert {:error, %{reason: "workspace_id mismatch"}} =
               join(
                 socket,
                 DaemonChannel,
                 "daemon:other-workspace",
                 register_payload("other-workspace")
               )
    end

    test "join registers workspaces in ets", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      assert {:ok, _reply, _socket} =
               join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      assert {:ok, entry} = Registry.lookup_workspace(user.id, @workspace_id)
      assert entry.machine_name == "test-machine"
      assert entry.status == "active"
      assert entry.agent_count == 2
    end

    test "join assigns machine_name, version, workspace_ids, and role", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "collaborator")

      assert {:ok, _reply, socket} =
               join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      assert socket.assigns.machine_name == "test-machine"
      assert socket.assigns.version == "0.1.0"
      assert socket.assigns.workspace_ids == [@workspace_id]
      assert socket.assigns.role == "collaborator"
    end

    test "join registers multiple workspaces", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      payload = %{
        "machine_name" => "multi-machine",
        "version" => "1.0",
        "workspaces" => [
          %{
            "id" => @workspace_id,
            "name" => "alpha",
            "project_path" => "/a",
            "team_id" => nil,
            "status" => "active",
            "agent_count" => 1
          },
          %{
            "id" => "ws-b",
            "name" => "beta",
            "project_path" => "/b",
            "team_id" => "team-1",
            "status" => "idle",
            "agent_count" => 0
          }
        ]
      }

      assert {:ok, _reply, _socket} =
               join(socket, DaemonChannel, "daemon:#{@workspace_id}", payload)

      assert {:ok, _} = Registry.lookup_workspace(user.id, @workspace_id)
      assert {:ok, _} = Registry.lookup_workspace(user.id, "ws-b")
    end
  end

  # --- Role-based command authorization ---

  describe "observer role authorization" do
    setup %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "observer")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      {:ok, socket: socket}
    end

    test "observer can issue read-only commands", %{socket: socket} do
      for action <- ~w(get_status get_history get_agents) do
        ref = push(socket, "command_request", %{"action" => action})
        assert_reply ref, :ok, %{"accepted" => true}
      end
    end

    test "observer cannot send_message", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "send_message"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "observer"
      assert reason =~ "send_message"
    end

    test "observer cannot kill_team", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "kill_team"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "observer"
    end

    test "observer cannot change_model", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "change_model"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "observer"
    end

    test "observer cannot steer_agent", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "steer_agent"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "observer"
    end
  end

  describe "collaborator role authorization" do
    setup %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "collaborator")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      {:ok, socket: socket}
    end

    test "collaborator can issue observer commands", %{socket: socket} do
      for action <- ~w(get_status get_history get_agents) do
        ref = push(socket, "command_request", %{"action" => action})
        assert_reply ref, :ok, %{"accepted" => true}
      end
    end

    test "collaborator can issue collaborator-level commands", %{socket: socket} do
      for action <- ~w(send_message approve_tool deny_tool pause_agent resume_agent) do
        ref = push(socket, "command_request", %{"action" => action})
        assert_reply ref, :ok, %{"accepted" => true}
      end
    end

    test "collaborator cannot kill_team", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "kill_team"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "collaborator"
    end

    test "collaborator cannot change_model", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "change_model"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "collaborator"
    end

    test "collaborator cannot steer_agent", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "steer_agent"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "collaborator"
    end

    test "collaborator cannot cancel", %{socket: socket} do
      ref = push(socket, "command_request", %{"action" => "cancel"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "collaborator"
    end
  end

  describe "owner role authorization" do
    setup %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      {:ok, socket: socket}
    end

    test "owner can issue all commands", %{socket: socket} do
      all_commands =
        ~w(get_status get_history get_agents send_message approve_tool deny_tool pause_agent resume_agent kill_team change_model steer_agent cancel)

      for action <- all_commands do
        ref = push(socket, "command_request", %{"action" => action})
        assert_reply ref, :ok, %{"accepted" => true}
      end
    end
  end

  # --- Heartbeat ---

  describe "heartbeat" do
    test "pushing heartbeat updates registry and returns ack", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      {:ok, entry_before} = Registry.lookup_workspace(user.id, @workspace_id)

      ref = push(socket, "heartbeat", %{})
      assert_reply ref, :ok, ack

      assert is_binary(ack["timestamp"])

      {:ok, entry_after} = Registry.lookup_workspace(user.id, @workspace_id)

      assert DateTime.compare(entry_after.last_heartbeat, entry_before.last_heartbeat) in [
               :eq,
               :gt
             ]
    end
  end

  # --- Event broadcasting ---

  describe "event" do
    test "pushing event broadcasts to PubSub", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:#{@workspace_id}")

      push(socket, "event", %{
        "workspace_id" => @workspace_id,
        "session_id" => "sess-1",
        "team_id" => nil,
        "event_type" => "agent.stream.delta",
        "data" => %{"delta" => "Hello"}
      })

      assert_receive {:relay_event, event}, 1000
      assert event.workspace_id == @workspace_id
      assert event.event_type == "agent.stream.delta"
      assert event.data == %{"delta" => "Hello"}
    end
  end

  # --- Workspace update ---

  describe "workspace_update" do
    test "pushing workspace_update modifies registry", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:workspaces:#{user.id}")

      push(socket, "workspace_update", %{
        "workspace_id" => @workspace_id,
        "name" => "loomkin-updated",
        "project_path" => nil,
        "team_id" => nil,
        "status" => "idle",
        "agent_count" => 0
      })

      assert_receive {:workspace_update, update}, 1000
      assert update.workspace_id == @workspace_id
      assert update.status == "idle"

      {:ok, entry} = Registry.lookup_workspace(user.id, @workspace_id)
      assert entry.status == "idle"
      assert entry.agent_count == 0
      assert entry.workspace_name == "loomkin-updated"
    end

    test "workspace_update for unowned workspace is rejected", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      # Pre-register an unrelated workspace
      Registry.register_workspace(user.id, "ws-unowned", %{
        channel_pid: self(),
        machine_name: "test-machine",
        status: "starting",
        team_id: nil,
        agent_count: 0,
        last_heartbeat: DateTime.utc_now(),
        project_path: "/unowned",
        workspace_name: "unowned-ws"
      })

      ref =
        push(socket, "workspace_update", %{
          "workspace_id" => "ws-unowned",
          "name" => "hacked",
          "project_path" => "/unowned",
          "team_id" => nil,
          "status" => "active",
          "agent_count" => 99
        })

      # Synchronize: wait for the channel to process the message
      refute_reply ref, :ok, 200

      # The update should have been rejected -- original values preserved
      {:ok, entry} = Registry.lookup_workspace(user.id, "ws-unowned")
      assert entry.status == "starting"
      assert entry.agent_count == 0
    end
  end

  # --- Cleanup ---

  describe "terminate/cleanup" do
    test "leaving channel cleans up registry", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      assert {:ok, _} = Registry.lookup_workspace(user.id, @workspace_id)

      Process.unlink(socket.channel_pid)
      monitor_ref = Process.monitor(socket.channel_pid)
      ref = leave(socket)
      assert_reply ref, :ok

      # Wait for the channel process to terminate
      assert_receive {:DOWN, ^monitor_ref, :process, _, _}, 1000

      assert :error = Registry.lookup_workspace(user.id, @workspace_id)
    end
  end

  # --- Unknown messages ---

  describe "unknown messages" do
    test "unknown message type is ignored", %{user: user} do
      {:ok, socket} = connect_socket(user.id, @workspace_id, role: "owner")

      {:ok, _reply, socket} =
        join(socket, DaemonChannel, "daemon:#{@workspace_id}", register_payload())

      ref = push(socket, "bogus_message", %{"data" => "test"})
      refute_reply ref, :ok
    end
  end

  # --- authorized?/2 unit tests ---

  describe "authorized?/2" do
    test "observer can only access read-only commands" do
      assert DaemonChannel.authorized?("observer", "get_status")
      assert DaemonChannel.authorized?("observer", "get_history")
      assert DaemonChannel.authorized?("observer", "get_agents")
      refute DaemonChannel.authorized?("observer", "send_message")
      refute DaemonChannel.authorized?("observer", "kill_team")
    end

    test "collaborator can access observer + collaborator commands" do
      assert DaemonChannel.authorized?("collaborator", "get_status")
      assert DaemonChannel.authorized?("collaborator", "send_message")
      assert DaemonChannel.authorized?("collaborator", "approve_tool")
      assert DaemonChannel.authorized?("collaborator", "deny_tool")
      assert DaemonChannel.authorized?("collaborator", "pause_agent")
      assert DaemonChannel.authorized?("collaborator", "resume_agent")
      refute DaemonChannel.authorized?("collaborator", "kill_team")
      refute DaemonChannel.authorized?("collaborator", "change_model")
      refute DaemonChannel.authorized?("collaborator", "steer_agent")
      refute DaemonChannel.authorized?("collaborator", "cancel")
    end

    test "owner can access all commands" do
      for action <-
            ~w(get_status get_history get_agents send_message approve_tool deny_tool pause_agent resume_agent kill_team change_model steer_agent cancel) do
        assert DaemonChannel.authorized?("owner", action)
      end
    end

    test "unknown role cannot access anything" do
      refute DaemonChannel.authorized?("admin", "get_status")
      refute DaemonChannel.authorized?("", "get_status")
    end

    test "unknown action is rejected for all roles" do
      refute DaemonChannel.authorized?("owner", "drop_database")
      refute DaemonChannel.authorized?("collaborator", "drop_database")
      refute DaemonChannel.authorized?("observer", "drop_database")
    end
  end
end
