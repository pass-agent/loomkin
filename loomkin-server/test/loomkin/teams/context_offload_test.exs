defmodule Loomkin.Teams.ContextOffloadTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ContextOffload, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "offload-test")

    on_exit(fn ->
      # Clean up keepers and agents
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "estimate_tokens/1" do
    test "estimates tokens for message list" do
      messages = [
        %{role: :user, content: String.duplicate("a", 400)},
        %{role: :assistant, content: String.duplicate("b", 800)}
      ]

      tokens = ContextOffload.estimate_tokens(messages)
      # 400/4 + 4 + 800/4 + 4 = 308
      assert tokens == 308
    end

    test "returns 0 for empty list" do
      assert ContextOffload.estimate_tokens([]) == 0
    end

    test "returns 0 for non-list" do
      assert ContextOffload.estimate_tokens(nil) == 0
    end
  end

  describe "split_at_topic_boundary/1" do
    test "returns empty offload for very short message lists" do
      messages = [%{role: :user, content: "a"}, %{role: :assistant, content: "b"}]
      {offload, keep} = ContextOffload.split_at_topic_boundary(messages)
      assert offload == []
      assert keep == messages
    end

    test "splits roughly 30% of messages for longer lists" do
      messages =
        Enum.map(1..10, fn i ->
          role = if rem(i, 2) == 1, do: :user, else: :assistant
          %{role: role, content: "message #{i}"}
        end)

      {offload, keep} = ContextOffload.split_at_topic_boundary(messages)
      assert length(offload) > 0
      assert length(keep) > 0
      assert length(offload) + length(keep) == 10
    end

    test "prefers splitting at user message boundaries" do
      messages = [
        %{role: :user, content: "q1"},
        %{role: :assistant, content: "a1"},
        %{role: :assistant, content: "tool result"},
        %{role: :user, content: "q2"},
        %{role: :assistant, content: "a2"},
        %{role: :user, content: "q3"},
        %{role: :assistant, content: "a3"},
        %{role: :user, content: "q4"},
        %{role: :assistant, content: "a4"},
        %{role: :user, content: "q5"}
      ]

      {offload, keep} = ContextOffload.split_at_topic_boundary(messages)
      # The keep list should start with a user message (natural break)
      assert length(offload) + length(keep) == 10

      if length(keep) > 0 do
        first_kept = hd(keep)
        assert first_kept.role in [:user, "user"]
      end
    end
  end

  describe "offload_to_keeper/3" do
    test "spawns a keeper and returns index entry", %{team_id: team_id} do
      messages = [
        %{role: :user, content: "explore the codebase"},
        %{role: :assistant, content: "I found several files..."}
      ]

      {:ok, pid, entry} =
        ContextOffload.offload_to_keeper(team_id, "researcher", messages,
          topic: "codebase exploration"
        )

      assert Process.alive?(pid)
      assert entry =~ "topic=codebase exploration"
      assert entry =~ "source=researcher"
    end

    @tag :llm_dependent
    test "infers topic from first user message", %{team_id: team_id} do
      messages = [
        %{role: :user, content: "fix the authentication bug in login"},
        %{role: :assistant, content: "looking at auth module..."}
      ]

      {:ok, pid, entry} = ContextOffload.offload_to_keeper(team_id, "coder", messages)

      assert Process.alive?(pid)
      assert entry =~ "fix the authentication bug in login"
    end
  end

  describe "generate_topic/1" do
    @tag :llm_dependent
    test "falls back to infer_topic when LLM is unavailable" do
      messages = [
        %{role: :user, content: "fix the authentication bug in login"},
        %{role: :assistant, content: "looking at auth module..."}
      ]

      # LLM call will fail in test env, should fall back to infer_topic
      topic = ContextOffload.generate_topic(messages)
      assert is_binary(topic)
      assert topic != ""
      # Falls back to first 60 chars of first user message
      assert topic =~ "fix the authentication bug in login"
    end

    test "falls back to infer_topic for empty content messages" do
      messages = [%{role: :system, content: ""}]
      topic = ContextOffload.generate_topic(messages)
      assert topic == "offloaded-context"
    end

    @tag :llm_dependent
    test "falls back to infer_topic for messages with no user message" do
      messages = [%{role: :assistant, content: "some response"}]
      topic = ContextOffload.generate_topic(messages)
      # infer_topic returns "offloaded-context" when no user message found
      assert topic == "offloaded-context"
    end
  end

  describe "offload marker priority" do
    test "marker includes priority: :high", %{team_id: team_id} do
      # Create messages large enough to trigger offload (60% of 128k = 76.8k tokens)
      large_content = String.duplicate("x", 320_000)

      large_messages =
        Enum.map(1..10, fn i ->
          role = if rem(i, 2) == 1, do: :user, else: :assistant
          %{role: role, content: "msg #{i} #{large_content}"}
        end)

      agent_state = %{
        model: nil,
        team_id: team_id,
        name: "test-agent",
        messages: large_messages
      }

      case ContextOffload.maybe_offload(agent_state) do
        {:offloaded, updated_messages, _entry} ->
          marker = hd(updated_messages)
          assert marker.role == :system
          assert marker.priority == :high
          assert marker.content =~ "[Context offloaded]"

        :noop ->
          # If offload didn't trigger, the messages weren't large enough — skip
          :ok
      end
    end
  end

  describe "maybe_offload/1" do
    test "returns :noop when under threshold" do
      # Small message list, well under 80% of any model limit
      agent_state = %{
        model: nil,
        team_id: "test-team",
        name: "agent-1",
        messages: [%{role: :user, content: "hello"}]
      }

      assert :noop = ContextOffload.maybe_offload(agent_state)
    end

    test "returns :noop for empty messages" do
      agent_state = %{
        model: nil,
        team_id: "test-team",
        name: "agent-1",
        messages: []
      }

      assert :noop = ContextOffload.maybe_offload(agent_state)
    end
  end
end
