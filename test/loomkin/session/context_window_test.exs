defmodule Loomkin.Session.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Loomkin.Session.ContextWindow

  describe "estimate_tokens/1" do
    test "estimates tokens as chars / 4" do
      # 20 chars -> 5 tokens
      assert ContextWindow.estimate_tokens("12345678901234567890") == 5
    end

    test "returns 0 for nil" do
      assert ContextWindow.estimate_tokens(nil) == 0
    end

    test "returns 0 for empty string" do
      assert ContextWindow.estimate_tokens("") == 0
    end
  end

  describe "model_limit/1" do
    test "returns default 128_000 for nil" do
      assert ContextWindow.model_limit(nil) == 128_000
    end

    test "returns default for unknown model" do
      assert ContextWindow.model_limit("unknown:nonexistent-model") == 128_000
    end
  end

  describe "allocate_budget/2" do
    test "returns all zones with defaults" do
      budget = ContextWindow.allocate_budget(nil)

      assert budget.system_prompt == 2048
      assert budget.decision_context == 1024
      assert budget.repo_map == 2048
      assert budget.tool_definitions == 2048
      assert budget.reserved_output == 4096
      # history = 128_000 - (2048 + 1024 + 2048 + 2048 + 4096) = 116_736
      assert budget.history == 116_736
    end

    test "respects custom options" do
      budget =
        ContextWindow.allocate_budget(nil,
          max_decision_tokens: 2048,
          max_repo_map_tokens: 4096,
          reserved_output: 8192
        )

      assert budget.decision_context == 2048
      assert budget.repo_map == 4096
      assert budget.reserved_output == 8192
      # history = 128_000 - (2048 + 2048 + 4096 + 2048 + 8192) = 109_568
      assert budget.history == 109_568
    end

    test "history is zero when zones exceed model limit" do
      budget =
        ContextWindow.allocate_budget(nil,
          max_decision_tokens: 50_000,
          max_repo_map_tokens: 50_000,
          reserved_output: 50_000
        )

      assert budget.history == 0
    end
  end

  describe "build_messages/3" do
    test "includes system prompt as first message" do
      messages = [%{role: :user, content: "Hello"}]
      result = ContextWindow.build_messages(messages, "You are helpful.")

      assert [system | _rest] = result
      assert system.role == :system
      assert system.content =~ "You are helpful."
    end

    test "includes recent messages that fit" do
      messages = [
        %{role: :user, content: "first"},
        %{role: :assistant, content: "response"},
        %{role: :user, content: "second"}
      ]

      result = ContextWindow.build_messages(messages, "system", max_tokens: 128_000)

      # System + all 3 messages should fit
      assert length(result) == 4
    end

    test "truncates older messages when context is small" do
      # Create messages that won't all fit in a tiny window
      long_content = String.duplicate("x", 400)

      messages = [
        %{role: :user, content: long_content},
        %{role: :assistant, content: long_content},
        %{role: :user, content: "latest"}
      ]

      # Very small window: system takes some, only latest should fit
      result =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 120,
          reserved_output: 10
        )

      # Should have system + at least the latest message
      assert hd(result).role == :system
      assert length(result) >= 2

      # The last user message should always be included
      last = List.last(result)
      assert last.content == "latest"
    end

    test "always includes system prompt even with zero available space" do
      result =
        ContextWindow.build_messages(
          [%{role: :user, content: "test"}],
          "system prompt",
          max_tokens: 10,
          reserved_output: 5
        )

      assert hd(result).role == :system
    end

    test "respects reserved_output option" do
      messages = [%{role: :user, content: String.duplicate("a", 4000)}]

      result_small =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 2000,
          reserved_output: 1500
        )

      result_large =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 2000,
          reserved_output: 100
        )

      # With larger reserved output, fewer messages should fit
      assert length(result_small) <= length(result_large)
    end

    test "backward compatible - works with just messages and system_prompt" do
      messages = [%{role: :user, content: "hello"}]
      result = ContextWindow.build_messages(messages, "system")

      assert length(result) == 2
      assert hd(result).role == :system
      assert hd(result).content =~ "system"
    end
  end

  describe "inject_decision_context/2" do
    test "returns parts unchanged when session_id is nil" do
      parts = ["System prompt"]
      assert ContextWindow.inject_decision_context(parts, nil) == parts
    end
  end

  describe "inject_repo_map/3" do
    test "returns parts unchanged when project_path is nil" do
      parts = ["System prompt"]
      assert ContextWindow.inject_repo_map(parts, nil) == parts
    end
  end

  describe "inject_project_rules/2" do
    test "returns parts unchanged when project_path is nil" do
      parts = ["System prompt"]
      assert ContextWindow.inject_project_rules(parts, nil) == parts
    end

    @tag :tmp_dir
    test "injects rules when LOOMKIN.md exists", %{tmp_dir: tmp_dir} do
      loom_md = """
      You are a careful coder.

      ## Rules
      - Always write tests
      - Use pattern matching
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), loom_md)

      parts = ["System prompt"]
      result = ContextWindow.inject_project_rules(parts, tmp_dir)

      # Should have appended project rules
      assert length(result) == 2
      assert List.last(result) =~ "Always write tests"
    end

    @tag :tmp_dir
    test "returns parts unchanged when no LOOMKIN.md exists", %{tmp_dir: tmp_dir} do
      parts = ["System prompt"]
      result = ContextWindow.inject_project_rules(parts, tmp_dir)
      assert result == parts
    end
  end

  describe "summarize_old_messages/2" do
    test "returns summary string with message count" do
      messages = [
        %{role: :user, content: "first message"},
        %{role: :assistant, content: "first response"},
        %{role: :user, content: "second message"}
      ]

      result = ContextWindow.summarize_old_messages(messages)
      assert result =~ "Summary of 3 earlier messages:"
      assert result =~ "first message"
    end

    test "truncates long content in summary" do
      long = String.duplicate("x", 500)
      messages = [%{role: :user, content: long}]

      result = ContextWindow.summarize_old_messages(messages)
      # The snippet should be capped at ~200 chars + prefix + "..."
      assert String.length(result) < 300
    end

    test "handles empty messages list" do
      result = ContextWindow.summarize_old_messages([])
      assert result == ""
    end
  end
end
