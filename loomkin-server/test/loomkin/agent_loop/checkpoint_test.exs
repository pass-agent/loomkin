defmodule Loomkin.AgentLoop.CheckpointTest do
  use ExUnit.Case, async: true

  alias Loomkin.AgentLoop.Checkpoint

  describe "Checkpoint struct" do
    test "creates a post_llm checkpoint with defaults" do
      checkpoint = %Checkpoint{
        type: :post_llm,
        agent_name: "coder-1",
        team_id: "team-abc",
        iteration: 2,
        planned_tools: [%{name: "file_read", arguments: %{"path" => "/tmp/test.ex"}}]
      }

      assert checkpoint.type == :post_llm
      assert checkpoint.agent_name == "coder-1"
      assert checkpoint.team_id == "team-abc"
      assert checkpoint.iteration == 2
      assert length(checkpoint.planned_tools) == 1
      assert checkpoint.messages == []
      assert checkpoint.tool_name == nil
      assert checkpoint.tool_result == nil
    end

    test "creates a post_tool checkpoint" do
      checkpoint = %Checkpoint{
        type: :post_tool,
        agent_name: "researcher",
        team_id: "team-xyz",
        iteration: 0,
        tool_name: "file_read",
        tool_result: "contents of file...",
        messages: [%{role: :user, content: "hello"}]
      }

      assert checkpoint.type == :post_tool
      assert checkpoint.tool_name == "file_read"
      assert checkpoint.tool_result == "contents of file..."
      assert length(checkpoint.messages) == 1
    end
  end
end
