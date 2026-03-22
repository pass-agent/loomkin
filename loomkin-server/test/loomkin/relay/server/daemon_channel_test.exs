defmodule Loomkin.Relay.Server.DaemonChannelTest do
  use Loomkin.DataCase, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: []

  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Relay.Server.Registry
  alias Loomkin.Relay.Server.Socket

  @endpoint LoomkinWeb.Endpoint

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

    # Create a real user and session token
    user = Loomkin.AccountsFixtures.user_fixture()
    token = Loomkin.Accounts.generate_user_session_token(user)

    {:ok, socket} = connect(Socket, %{"token" => Base.url_encode64(token, padding: false)})
    {:ok, socket: socket, user: user}
  end

  defp register_payload do
    %{
      "machine_name" => "test-machine",
      "version" => "0.1.0",
      "workspaces" => [
        %{
          "id" => "ws-1",
          "name" => "loomkin",
          "project_path" => "/home/user/loomkin",
          "team_id" => nil,
          "status" => "active",
          "agent_count" => 2
        }
      ]
    }
  end

  describe "join daemon:lobby" do
    test "daemon can join with register payload", %{socket: socket, user: user} do
      assert {:ok, _reply, socket} =
               join(socket, DaemonChannel, "daemon:lobby", register_payload())

      assert socket.assigns.machine_name == "test-machine"
      assert socket.assigns.version == "0.1.0"
      assert socket.assigns.workspace_ids == ["ws-1"]

      # Verify workspace registered in ETS
      assert {:ok, entry} = Registry.lookup_workspace(user.id, "ws-1")
      assert entry.machine_name == "test-machine"
      assert entry.status == "active"
      assert entry.agent_count == 2
    end

    test "join registers multiple workspaces", %{socket: socket, user: user} do
      payload = %{
        "machine_name" => "multi-machine",
        "version" => "1.0",
        "workspaces" => [
          %{
            "id" => "ws-a",
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

      assert {:ok, _reply, _socket} = join(socket, DaemonChannel, "daemon:lobby", payload)

      assert {:ok, _} = Registry.lookup_workspace(user.id, "ws-a")
      assert {:ok, _} = Registry.lookup_workspace(user.id, "ws-b")

      workspaces = Registry.list_workspaces(user.id)
      assert length(workspaces) == 2
    end
  end

  describe "heartbeat" do
    test "pushing heartbeat updates registry and returns ack", %{socket: socket, user: user} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

      {:ok, entry_before} = Registry.lookup_workspace(user.id, "ws-1")

      # Small delay to ensure timestamp differs
      Process.sleep(10)

      ref = push(socket, "heartbeat", %{})
      assert_reply ref, :ok, ack

      assert is_binary(ack["timestamp"])

      {:ok, entry_after} = Registry.lookup_workspace(user.id, "ws-1")

      assert DateTime.compare(entry_after.last_heartbeat, entry_before.last_heartbeat) in [
               :eq,
               :gt
             ]
    end
  end

  describe "event" do
    test "pushing event broadcasts to PubSub", %{socket: socket} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:ws-1")

      push(socket, "event", %{
        "workspace_id" => "ws-1",
        "session_id" => "sess-1",
        "team_id" => nil,
        "event_type" => "agent.stream.delta",
        "data" => %{"delta" => "Hello"}
      })

      assert_receive {:relay_event, event}, 1000
      assert event.workspace_id == "ws-1"
      assert event.event_type == "agent.stream.delta"
      assert event.data == %{"delta" => "Hello"}
    end
  end

  describe "workspace_update" do
    test "pushing workspace_update modifies registry", %{socket: socket, user: user} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

      Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:workspaces:#{user.id}")

      push(socket, "workspace_update", %{
        "workspace_id" => "ws-1",
        "name" => "loomkin-updated",
        "project_path" => nil,
        "team_id" => nil,
        "status" => "idle",
        "agent_count" => 0
      })

      assert_receive {:workspace_update, update}, 1000
      assert update.workspace_id == "ws-1"
      assert update.status == "idle"

      {:ok, entry} = Registry.lookup_workspace(user.id, "ws-1")
      assert entry.status == "idle"
      assert entry.agent_count == 0
      assert entry.workspace_name == "loomkin-updated"
    end

    test "workspace_update for unowned workspace is rejected", %{socket: socket, user: user} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

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

      push(socket, "workspace_update", %{
        "workspace_id" => "ws-unowned",
        "name" => "hacked",
        "project_path" => "/unowned",
        "team_id" => nil,
        "status" => "active",
        "agent_count" => 99
      })

      Process.sleep(50)

      # The update should have been rejected — original values preserved
      {:ok, entry} = Registry.lookup_workspace(user.id, "ws-unowned")
      assert entry.status == "starting"
      assert entry.agent_count == 0
    end
  end

  describe "terminate/cleanup" do
    test "leaving channel cleans up registry", %{socket: socket, user: user} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

      assert {:ok, _} = Registry.lookup_workspace(user.id, "ws-1")

      Process.unlink(socket.channel_pid)
      ref = leave(socket)
      assert_reply ref, :ok

      # Give process time to terminate
      Process.sleep(50)

      assert :error = Registry.lookup_workspace(user.id, "ws-1")
    end
  end

  describe "socket authentication" do
    test "connect fails without token" do
      assert :error = connect(Socket, %{})
    end

    test "connect fails with invalid token" do
      assert :error = connect(Socket, %{"token" => "invalid-token"})
    end
  end

  describe "unknown messages" do
    test "unknown message type is ignored", %{socket: socket} do
      {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:lobby", register_payload())

      ref = push(socket, "bogus_message", %{"data" => "test"})
      refute_reply ref, :ok
    end
  end
end
