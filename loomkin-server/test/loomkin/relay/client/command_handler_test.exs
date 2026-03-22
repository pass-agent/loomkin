defmodule Loomkin.Relay.Client.CommandHandlerTest do
  use ExUnit.Case, async: true

  alias Loomkin.Relay.Client.CommandHandler
  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.CommandResponse

  describe "unknown action" do
    test "returns error for unknown action" do
      cmd = %Command{
        request_id: "req-1",
        action: "totally_bogus",
        workspace_id: "ws-1",
        session_id: "sess-1",
        payload: %{}
      }

      result = CommandHandler.handle(cmd)

      assert %CommandResponse{} = result
      assert result.request_id == "req-1"
      assert result.status == "error"
      assert result.data["error"] =~ "unknown action"
    end
  end

  describe "kill_team without confirm" do
    test "returns error when confirm is not true" do
      cmd = %Command{
        request_id: "req-kill",
        action: "kill_team",
        workspace_id: "ws-1",
        payload: %{"team_id" => "team-1", "confirm" => false}
      }

      result = CommandHandler.handle(cmd)

      assert %CommandResponse{} = result
      assert result.status == "error"
      assert result.data["error"] =~ "confirm"
    end

    test "returns error when confirm is missing" do
      cmd = %Command{
        request_id: "req-kill-2",
        action: "kill_team",
        workspace_id: "ws-1",
        payload: %{"team_id" => "team-1"}
      }

      result = CommandHandler.handle(cmd)

      assert result.status == "error"
      assert result.data["error"] =~ "confirm"
    end
  end

  describe "response shape" do
    test "all responses have request_id, status, and data" do
      cmd = %Command{
        request_id: "req-shape",
        action: "unknown_action_xyz",
        workspace_id: "ws-1",
        payload: %{}
      }

      result = CommandHandler.handle(cmd)

      assert is_binary(result.request_id)
      assert result.request_id == "req-shape"
      assert result.status in ["ok", "error"]
      assert is_map(result.data)
    end
  end
end
