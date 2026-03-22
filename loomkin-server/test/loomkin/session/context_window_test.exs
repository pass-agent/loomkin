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
      assert budget.skills == 512
      assert budget.tool_definitions == 2048
      assert budget.reserved_output == 4096
      # history = 128_000 - (2048 + 1024 + 2048 + 512 + 2048 + 4096) = 116_224
      assert budget.history == 116_224
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
      # history = 128_000 - (2048 + 2048 + 4096 + 512 + 2048 + 8192) = 109_056
      assert budget.history == 109_056
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

  describe "select_recent priority retention" do
    test "high priority messages are always retained even when budget is tight" do
      # Create a mix of normal and high-priority messages
      long_content = String.duplicate("x", 400)

      messages = [
        %{role: :user, content: long_content},
        %{role: :system, content: "[Context offloaded] keeper:abc", priority: :high},
        %{role: :assistant, content: long_content},
        %{role: :system, content: "[Context offloaded] keeper:def", priority: :high},
        %{role: :user, content: "latest question"}
      ]

      # Use a very tight budget via build_messages so only a few messages fit
      result =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 200,
          reserved_output: 10
        )

      # System prompt is always first
      assert hd(result).role == :system

      # High priority markers should survive trimming
      contents = Enum.map(result, & &1.content)
      assert Enum.any?(contents, &(&1 =~ "keeper:abc"))
      assert Enum.any?(contents, &(&1 =~ "keeper:def"))
    end

    test "normal messages without priority are evicted first" do
      long = String.duplicate("y", 1000)

      messages = [
        %{role: :user, content: long},
        %{role: :assistant, content: long},
        %{role: :system, content: "important breadcrumb", priority: :high},
        %{role: :user, content: "recent"}
      ]

      result =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 400,
          reserved_output: 10
        )

      contents = Enum.map(result, & &1.content)
      # High priority breadcrumb should be present
      assert Enum.any?(contents, &(&1 =~ "important breadcrumb"))
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

  describe "compute_headroom/3" do
    test "returns floor for 32K context" do
      assert ContextWindow.compute_headroom(32_000, 55, 93) == 55
    end

    test "returns ceiling for 1M context" do
      assert ContextWindow.compute_headroom(1_000_000, 55, 93) == 93
    end

    test "returns ~71 for 128K context" do
      result = ContextWindow.compute_headroom(128_000, 55, 93)
      assert result >= 69 and result <= 73
    end

    test "clamps below 32K to floor" do
      assert ContextWindow.compute_headroom(8_000, 55, 93) == 55
    end

    test "clamps above 1M to ceiling" do
      assert ContextWindow.compute_headroom(2_000_000, 55, 93) == 93
    end

    test "works with different floor/ceiling values" do
      assert ContextWindow.compute_headroom(32_000, 40, 95) == 40
      assert ContextWindow.compute_headroom(1_000_000, 40, 95) == 95
    end

    test "returns same value when floor equals ceiling" do
      assert ContextWindow.compute_headroom(32_000, 75, 75) == 75
      assert ContextWindow.compute_headroom(128_000, 75, 75) == 75
      assert ContextWindow.compute_headroom(1_000_000, 75, 75) == 75
    end
  end

  describe "max_utilization_pct/1" do
    test "returns value in expected range for nil model" do
      result = ContextWindow.max_utilization_pct(nil)
      # nil model -> 128K default context limit
      assert result >= 55 and result <= 93
    end

    test "returns value in expected range for unknown model" do
      result = ContextWindow.max_utilization_pct("unknown:model")
      assert result >= 55 and result <= 93
    end
  end

  describe "context_usage_info/3" do
    test "includes system overhead for empty messages" do
      info = ContextWindow.context_usage_info(nil, [])
      # Default system overhead = 2048 + 1024 + 2048 + 512 + 2048 = 7680
      assert info.used_tokens == 7680
      assert info.usage_pct == 6
      assert info.total_tokens == 128_000
      assert info.threshold_pct >= 55
      assert info.threshold_pct <= 93
    end

    test "returns nonzero usage for messages with content" do
      messages = [
        %{role: :user, content: String.duplicate("x", 4000)},
        %{role: :assistant, content: String.duplicate("y", 4000)}
      ]

      info = ContextWindow.context_usage_info(nil, messages)
      assert info.usage_pct > 0
      # used_tokens includes system overhead (7680) + message tokens
      assert info.used_tokens > 7680
    end

    test "explicit system_overhead option overrides default" do
      info = ContextWindow.context_usage_info(nil, [], system_overhead: 10_000)
      assert info.used_tokens == 10_000
    end

    test "system_overhead: 0 reproduces legacy behavior" do
      info = ContextWindow.context_usage_info(nil, [], system_overhead: 0)
      assert info.used_tokens == 0
      assert info.usage_pct == 0
    end

    test "combines system overhead with message tokens" do
      # 400 chars = 100 tokens + 4 overhead = 104 per message
      messages = [%{role: :user, content: String.duplicate("x", 400)}]
      info = ContextWindow.context_usage_info(nil, messages)
      # 7680 (system) + 104 (message) = 7784
      assert info.used_tokens == 7784
    end
  end

  describe "summarize_old_messages/2" do
    @tag :skip
    test "returns summary string with message count" do
      # NOTE: Calls real LLM — skip until mocked
      messages = [
        %{role: :user, content: "first message"},
        %{role: :assistant, content: "first response"},
        %{role: :user, content: "second message"}
      ]

      result = ContextWindow.summarize_old_messages(messages)
      assert result =~ "Summary of 3 earlier messages:"
      assert result =~ "first message"
    end

    @tag :skip
    test "truncates long content in summary" do
      # NOTE: Calls real LLM — skip until mocked
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
