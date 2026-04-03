defmodule Loomkin.Teams.TopicsTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Topics

  describe "bus glob paths" do
    test "agent_all/0 returns agent wildcard" do
      assert Topics.agent_all() == "agent.**"
    end

    test "team_all/0 returns team wildcard" do
      assert Topics.team_all() == "team.**"
    end

    test "context_all/0 returns context wildcard" do
      assert Topics.context_all() == "context.**"
    end

    test "decision_all/0 returns decision wildcard" do
      assert Topics.decision_all() == "decision.**"
    end

    test "channel_all/0 returns channel wildcard" do
      assert Topics.channel_all() == "channel.**"
    end

    test "collaboration_all/0 returns collaboration wildcard" do
      assert Topics.collaboration_all() == "collaboration.**"
    end

    test "system_all/0 returns system wildcard" do
      assert Topics.system_all() == "system.**"
    end

    test "session_all/0 returns session wildcard" do
      assert Topics.session_all() == "session.**"
    end
  end

  describe "per-entity paths" do
    test "agent_stream/1 returns agent stream path" do
      assert Topics.agent_stream("agent-1") == "agent.stream.agent-1"
    end

    test "collaboration_vote_all/0 returns vote wildcard" do
      assert Topics.collaboration_vote_all() == "collaboration.vote.*"
    end
  end

  describe "phoenix pubsub topics" do
    test "team_pubsub/1 returns team pubsub topic" do
      assert Topics.team_pubsub("abc123") == "team:abc123"
    end
  end

  describe "global_bus_paths/0" do
    test "returns a list of 7 glob paths" do
      paths = Topics.global_bus_paths()
      assert is_list(paths)
      assert length(paths) == 7
    end

    test "includes all major topic wildcards" do
      paths = Topics.global_bus_paths()
      assert "agent.**" in paths
      assert "team.**" in paths
      assert "context.**" in paths
      assert "decision.**" in paths
      assert "channel.**" in paths
      assert "collaboration.**" in paths
      assert "session.**" in paths
    end
  end
end
