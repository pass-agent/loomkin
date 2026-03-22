defmodule Loomkin.Channels.Discord.FormatterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Discord.Formatter

  describe "format_agent_message/2" do
    test "wraps agent name in bold" do
      result = Formatter.format_agent_message("researcher", "Found a bug")
      assert result == "**researcher**\nFound a bug"
    end

    test "preserves content as-is (no escaping needed for Discord)" do
      result = Formatter.format_agent_message("agent", "Hello *world* `code` _italic_")
      assert result == "**agent**\nHello *world* `code` _italic_"
    end
  end

  describe "split_message/1" do
    test "returns single chunk for short messages" do
      assert Formatter.split_message("short") == ["short"]
    end

    test "returns single chunk for messages at the 2000 char limit" do
      text = String.duplicate("a", 2000)
      assert [^text] = Formatter.split_message(text)
    end

    test "splits long messages into chunks under 2000 chars" do
      text = String.duplicate("a", 3000)
      chunks = Formatter.split_message(text)

      assert length(chunks) >= 2

      for chunk <- chunks do
        assert byte_size(chunk) <= 2000
      end
    end

    test "prefers splitting at newlines" do
      line = String.duplicate("x", 1000)
      text = "#{line}\n#{line}\n#{line}"

      chunks = Formatter.split_message(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert byte_size(chunk) <= 2000
      end
    end

    test "handles empty string" do
      assert Formatter.split_message("") == [""]
    end
  end

  describe "to_discord_markdown/1" do
    test "strips HTML tags" do
      assert Formatter.to_discord_markdown("hello <b>world</b>") == "hello world"
    end

    test "leaves regular markdown intact" do
      text = "**bold** *italic* `code`"
      assert Formatter.to_discord_markdown(text) == text
    end
  end

  describe "activity_embed/3" do
    test "creates embed map with title and description" do
      embed = Formatter.activity_embed("Task Complete", "Finished the analysis")

      assert embed.title == "Task Complete"
      assert embed.description == "Finished the analysis"
      assert is_integer(embed.color)
      assert is_binary(embed.timestamp)
    end

    test "uses role-specific colors" do
      lead_embed = Formatter.activity_embed("x", "y", :lead)
      coder_embed = Formatter.activity_embed("x", "y", :coder)
      default_embed = Formatter.activity_embed("x", "y", :unknown)

      assert lead_embed.color == 0xFF6B35
      assert coder_embed.color == 0x45B7D1
      assert default_embed.color == 0x7C8DB5
    end

    test "supports all defined roles" do
      roles = [:lead, :researcher, :coder, :reviewer, :tester, :other]

      for role <- roles do
        embed = Formatter.activity_embed("title", "desc", role)
        assert is_integer(embed.color)
      end
    end
  end

  describe "question_buttons/2" do
    test "creates action rows with buttons" do
      rows = Formatter.question_buttons("q-1", ["Yes", "No"])

      assert length(rows) == 1
      [row] = rows
      assert row.type == 1
      assert length(row.components) == 2

      [btn1, btn2] = row.components
      assert btn1.type == 2
      assert btn1.style == 1
      assert btn1.label == "Yes"
      assert btn1.custom_id == "ask_user:q-1:0"
      assert btn2.label == "No"
      assert btn2.custom_id == "ask_user:q-1:1"
    end

    test "splits buttons into rows of 5" do
      options = Enum.map(1..7, &"Option #{&1}")
      rows = Formatter.question_buttons("q-2", options)

      assert length(rows) == 2
      assert length(hd(rows).components) == 5
      assert length(List.last(rows).components) == 2
    end

    test "truncates long labels to 80 chars" do
      long_label = String.duplicate("x", 100)
      rows = Formatter.question_buttons("q-3", [long_label])

      [row] = rows
      [btn] = row.components
      assert String.length(btn.label) <= 80
      assert String.ends_with?(btn.label, "...")
    end

    test "handles empty options" do
      rows = Formatter.question_buttons("q-4", [])
      assert rows == []
    end
  end
end
