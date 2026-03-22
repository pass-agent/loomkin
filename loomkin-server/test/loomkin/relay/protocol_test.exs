defmodule Loomkin.Relay.ProtocolTest do
  use ExUnit.Case, async: true

  alias Loomkin.Relay.Protocol
  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.CommandResponse
  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Relay.Protocol.Heartbeat
  alias Loomkin.Relay.Protocol.HeartbeatAck
  alias Loomkin.Relay.Protocol.Register
  alias Loomkin.Relay.Protocol.WorkspaceUpdate

  describe "Register encode/decode roundtrip" do
    test "preserves all fields" do
      msg = %Register{
        machine_name: "brandons-mbp",
        version: "0.1.0",
        workspaces: [
          %{
            id: "ws-1",
            name: "loomkin",
            project_path: "/home/user/loomkin",
            team_id: "team-abc",
            status: "active",
            agent_count: 3
          },
          %{
            id: "ws-2",
            name: "other-project",
            project_path: "/home/user/other",
            team_id: nil,
            status: "idle",
            agent_count: 0
          }
        ]
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %Register{} = decoded
      assert decoded.machine_name == "brandons-mbp"
      assert decoded.version == "0.1.0"
      assert length(decoded.workspaces) == 2

      [ws1, ws2] = decoded.workspaces
      assert ws1.id == "ws-1"
      assert ws1.name == "loomkin"
      assert ws1.project_path == "/home/user/loomkin"
      assert ws1.team_id == "team-abc"
      assert ws1.status == "active"
      assert ws1.agent_count == 3

      assert ws2.id == "ws-2"
      assert ws2.team_id == nil
      assert ws2.agent_count == 0
    end

    test "handles empty workspaces list" do
      msg = %Register{machine_name: "test", version: "1.0", workspaces: []}

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert decoded.workspaces == []
    end
  end

  describe "Heartbeat encode/decode roundtrip" do
    test "preserves timestamp" do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      msg = %Heartbeat{timestamp: ts}

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %Heartbeat{} = decoded
      assert decoded.timestamp == ts
    end

    test "generates timestamp when nil" do
      msg = %Heartbeat{timestamp: nil}

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %Heartbeat{} = decoded
      assert is_binary(decoded.timestamp)
    end
  end

  describe "HeartbeatAck encode/decode roundtrip" do
    test "preserves timestamp" do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      msg = %HeartbeatAck{timestamp: ts}

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %HeartbeatAck{} = decoded
      assert decoded.timestamp == ts
    end
  end

  describe "Command encode/decode roundtrip" do
    test "preserves all fields" do
      msg = %Command{
        request_id: "req-123",
        action: "send_message",
        workspace_id: "ws-1",
        session_id: "sess-456",
        payload: %{"text" => "hello world"}
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %Command{} = decoded
      assert decoded.request_id == "req-123"
      assert decoded.action == "send_message"
      assert decoded.workspace_id == "ws-1"
      assert decoded.session_id == "sess-456"
      assert decoded.payload == %{"text" => "hello world"}
    end

    test "defaults payload to empty map" do
      msg = %Command{
        request_id: "req-1",
        action: "cancel",
        workspace_id: "ws-1",
        session_id: nil,
        payload: %{}
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert decoded.payload == %{}
      assert decoded.session_id == nil
    end
  end

  describe "CommandResponse encode/decode roundtrip" do
    test "preserves ok response" do
      msg = CommandResponse.ok("req-123", %{"messages" => []})

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %CommandResponse{} = decoded
      assert decoded.request_id == "req-123"
      assert decoded.status == "ok"
      assert decoded.data == %{"messages" => []}
    end

    test "preserves error response" do
      msg = CommandResponse.error("req-456", "session not found")

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %CommandResponse{} = decoded
      assert decoded.request_id == "req-456"
      assert decoded.status == "error"
      assert decoded.data == %{"error" => "session not found"}
    end

    test "defaults data to empty map" do
      msg = %CommandResponse{request_id: "req-1", status: "ok", data: %{}}

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert decoded.data == %{}
    end
  end

  describe "Event encode/decode roundtrip" do
    test "preserves all fields" do
      msg = %Event{
        workspace_id: "ws-1",
        session_id: "sess-1",
        team_id: "team-1",
        event_type: "agent.stream.delta",
        data: %{"delta" => "Hello"}
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %Event{} = decoded
      assert decoded.workspace_id == "ws-1"
      assert decoded.session_id == "sess-1"
      assert decoded.team_id == "team-1"
      assert decoded.event_type == "agent.stream.delta"
      assert decoded.data == %{"delta" => "Hello"}
    end

    test "handles nil session_id and team_id" do
      msg = %Event{
        workspace_id: "ws-1",
        session_id: nil,
        team_id: nil,
        event_type: "session.status_changed",
        data: %{"status" => "idle"}
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert decoded.session_id == nil
      assert decoded.team_id == nil
    end
  end

  describe "WorkspaceUpdate encode/decode roundtrip" do
    test "preserves all fields" do
      msg = %WorkspaceUpdate{
        workspace_id: "ws-1",
        name: "loomkin",
        project_path: "/home/user/loomkin",
        team_id: "team-abc",
        status: "active",
        agent_count: 5
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert %WorkspaceUpdate{} = decoded
      assert decoded.workspace_id == "ws-1"
      assert decoded.name == "loomkin"
      assert decoded.project_path == "/home/user/loomkin"
      assert decoded.team_id == "team-abc"
      assert decoded.status == "active"
      assert decoded.agent_count == 5
    end

    test "defaults agent_count to 0" do
      msg = %WorkspaceUpdate{
        workspace_id: "ws-1",
        status: "idle",
        agent_count: 0
      }

      assert {:ok, json} = Protocol.encode(msg)
      assert {:ok, decoded} = Protocol.decode(json)

      assert decoded.agent_count == 0
    end
  end

  describe "decode_map/1 error handling" do
    test "returns error for unknown type" do
      assert {:error, :unknown_type} = Protocol.decode_map(%{"type" => "bogus"})
    end

    test "returns error for missing type" do
      assert {:error, :unknown_type} = Protocol.decode_map(%{"foo" => "bar"})
    end

    test "returns error for empty map" do
      assert {:error, :unknown_type} = Protocol.decode_map(%{})
    end
  end

  describe "decode/1 error handling" do
    test "returns error for invalid JSON" do
      assert {:error, _} = Protocol.decode("not json at all")
    end

    test "returns error for JSON with unknown type" do
      json = Jason.encode!(%{"type" => "unknown_msg"})
      assert {:error, :unknown_type} = Protocol.decode(json)
    end

    test "returns error for empty JSON object" do
      assert {:error, :unknown_type} = Protocol.decode("{}")
    end
  end

  describe "valid_actions/0" do
    test "returns list of action strings" do
      actions = Protocol.valid_actions()

      assert is_list(actions)
      assert "send_message" in actions
      assert "cancel" in actions
      assert "get_history" in actions
      assert "get_status" in actions
      assert "approve_tool" in actions
      assert "deny_tool" in actions
      assert "get_agents" in actions
      assert "pause_agent" in actions
      assert "resume_agent" in actions
      assert "steer_agent" in actions
      assert "change_model" in actions
      assert "kill_team" in actions
    end
  end
end
