defmodule Loomkin.Channels.Telegram.FormatterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Telegram.Formatter

  describe "escape/1" do
    test "escapes all MarkdownV2 special characters" do
      # Each special char should be preceded by a backslash
      special = "_*[]()~`>#+-=|{}.!"

      escaped = Formatter.escape(special)

      for char <- String.graphemes(special) do
        assert String.contains?(escaped, "\\#{char}"),
               "Expected '#{char}' to be escaped in: #{escaped}"
      end
    end

    test "leaves normal text unchanged" do
      assert Formatter.escape("hello world") == "hello world"
    end

    test "escapes mixed content" do
      assert Formatter.escape("Hello (world)!") == "Hello \\(world\\)\\!"
    end

    test "handles empty string" do
      assert Formatter.escape("") == ""
    end

    test "escapes multiple occurrences" do
      assert Formatter.escape("a.b.c") == "a\\.b\\.c"
    end
  end

  describe "format_agent_message/2" do
    test "wraps agent name in bold and escapes content" do
      result = Formatter.format_agent_message("lead", "Hello!")

      assert result == "*lead*\nHello\\!"
    end

    test "escapes special chars in both name and content" do
      result = Formatter.format_agent_message("agent_1", "Result: (ok)")

      assert result =~ "*agent\\_1*"
      assert result =~ "\\(ok\\)"
    end
  end

  describe "split_message/1" do
    test "returns single chunk for short messages" do
      assert Formatter.split_message("short") == ["short"]
    end

    test "returns single chunk for messages at the limit" do
      text = String.duplicate("a", 4096)
      assert [^text] = Formatter.split_message(text)
    end

    test "splits long messages into multiple chunks" do
      # Create a message larger than 4096 chars
      text = String.duplicate("a", 5000)
      chunks = Formatter.split_message(text)

      assert length(chunks) >= 2

      # All chunks should be at or under the limit
      for chunk <- chunks do
        assert byte_size(chunk) <= 4096
      end

      # Rejoined text should equal original (minus possible trailing newline trimming)
      rejoined = Enum.join(chunks)
      assert String.length(rejoined) == String.length(text)
    end

    test "prefers splitting at newline boundaries" do
      line = String.duplicate("x", 2000)
      text = "#{line}\n#{line}\n#{line}"

      chunks = Formatter.split_message(text)

      # Should split between lines, not in the middle of one
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert byte_size(chunk) <= 4096
      end
    end

    test "handles text with no newlines" do
      text = String.duplicate("x", 8192)
      chunks = Formatter.split_message(text)

      assert length(chunks) >= 2

      for chunk <- chunks do
        assert byte_size(chunk) <= 4096
      end
    end

    test "handles empty string" do
      assert Formatter.split_message("") == [""]
    end
  end

  describe "format_activity/1" do
    test "formats conflict_detected event" do
      event = %{type: :conflict_detected, agents: ["coder", "researcher"]}
      result = Formatter.format_activity(event)

      assert result =~ "Conflict detected"
      assert result =~ "coder, researcher"
    end

    test "formats consensus_reached event" do
      event = %{type: :consensus_reached, topic: "Use GenServer"}
      result = Formatter.format_activity(event)

      assert result =~ "Consensus reached"
      assert result =~ "Use GenServer"
    end

    test "formats task_completed event" do
      event = %{type: :task_completed, agent_name: "coder", task: "Implement auth"}
      result = Formatter.format_activity(event)

      assert result =~ "coder"
      assert result =~ "completed"
      assert result =~ "Implement auth"
    end

    test "formats unknown event type" do
      event = %{type: :something_else}
      result = Formatter.format_activity(event)

      assert result =~ "Activity"
      # The underscore gets escaped for MarkdownV2
      assert result =~ "something\\_else"
    end

    test "handles missing fields gracefully" do
      event = %{type: :conflict_detected}
      result = Formatter.format_activity(event)
      assert result =~ "Conflict detected"

      event2 = %{}
      result2 = Formatter.format_activity(event2)
      assert result2 =~ "Activity"
    end
  end
end
