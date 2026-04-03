defmodule Loomkin.Vault.ParserTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.Parser

  describe "parse/1" do
    test "parses content with valid frontmatter" do
      content = """
      ---
      title: My Note
      type: session
      tags:
        - elixir
        - otp
      ---
      # Hello World

      This is the body.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.title == "My Note"
      assert entry.entry_type == "session"
      assert entry.tags == ["elixir", "otp"]
      assert entry.body =~ "# Hello World"
      assert entry.body =~ "This is the body."
      assert entry.metadata["title"] == "My Note"
      assert entry.metadata["type"] == "session"
    end

    test "parses content without frontmatter (body only)" do
      content = "# Just a heading\n\nSome text here."

      assert {:ok, entry} = Parser.parse(content)
      assert entry.title == nil
      assert entry.entry_type == nil
      assert entry.tags == []
      assert entry.metadata == %{}
      assert entry.body == "# Just a heading\n\nSome text here."
    end

    test "parses content with empty frontmatter" do
      content = """
      ---
      ---
      Body after empty frontmatter.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.title == nil
      assert entry.entry_type == nil
      assert entry.tags == []
      assert entry.metadata == %{}
      assert entry.body == "Body after empty frontmatter."
    end

    test "extracts title, entry_type, and tags from frontmatter" do
      content = """
      ---
      title: Design Doc
      type: architecture
      tags:
        - design
        - vault
      priority: high
      ---
      Content goes here.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.title == "Design Doc"
      assert entry.entry_type == "architecture"
      assert entry.tags == ["design", "vault"]
      assert entry.metadata["priority"] == "high"
    end

    test "preserves extra metadata fields" do
      content = """
      ---
      title: Test
      author: alice
      version: 3
      ---
      Body.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.metadata["author"] == "alice"
      assert entry.metadata["version"] == 3
      assert entry.title == "Test"
    end

    test "handles empty string" do
      assert {:ok, entry} = Parser.parse("")
      assert entry.body == ""
      assert entry.metadata == %{}
      assert entry.tags == []
    end

    test "handles content with only frontmatter and no body" do
      content = """
      ---
      title: No Body
      type: note
      ---
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.title == "No Body"
      assert entry.entry_type == "note"
      assert entry.body == ""
    end

    test "handles tags as empty list" do
      content = """
      ---
      title: Empty Tags
      tags: []
      ---
      Some body.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.tags == []
    end

    test "normalizes non-string tags to strings" do
      content = """
      ---
      tags:
        - 42
        - true
        - hello
      ---
      Body.
      """

      assert {:ok, entry} = Parser.parse(content)
      assert entry.tags == ["42", "true", "hello"]
    end
  end

  describe "parse!/1" do
    test "returns entry on success" do
      content = """
      ---
      title: Quick
      ---
      Body.
      """

      entry = Parser.parse!(content)
      assert %Entry{} = entry
      assert entry.title == "Quick"
    end

    test "raises on invalid YAML" do
      # Broken YAML: tab characters are invalid in YAML
      content = "---\n\t: bad\n---\nBody."

      assert_raise ArgumentError, ~r/failed to parse vault entry/, fn ->
        Parser.parse!(content)
      end
    end
  end

  describe "serialize/1" do
    test "serializes entry with frontmatter and body" do
      entry = %Entry{
        title: "My Note",
        entry_type: "session",
        tags: ["elixir", "otp"],
        body: "# Hello\n\nContent here.",
        metadata: %{"title" => "My Note", "type" => "session", "tags" => ["elixir", "otp"]}
      }

      result = Parser.serialize(entry)
      assert result =~ "---\n"
      assert result =~ "title: My Note\n"
      assert result =~ "type: session\n"
      assert result =~ "  - elixir\n"
      assert result =~ "  - otp\n"
      assert result =~ "# Hello\n\nContent here."
    end

    test "serializes entry with body only (no metadata)" do
      entry = %Entry{body: "Just text.", metadata: %{}, tags: []}

      result = Parser.serialize(entry)
      assert result == "Just text."
    end

    test "serializes entry with nil body" do
      entry = %Entry{title: "Title Only", metadata: %{"title" => "Title Only"}, tags: []}

      result = Parser.serialize(entry)
      assert result =~ "title: Title Only"
    end

    test "serializes entry with empty tags as no tags key" do
      entry = %Entry{title: "No Tags", metadata: %{"title" => "No Tags"}, tags: []}

      result = Parser.serialize(entry)
      refute result =~ "tags:"
    end
  end

  describe "round-trip" do
    test "parse then serialize then parse produces same result" do
      content = """
      ---
      title: Round Trip
      type: note
      tags:
        - alpha
        - beta
      author: bob
      ---
      # Heading

      Body paragraph.
      """

      assert {:ok, entry1} = Parser.parse(content)
      serialized = Parser.serialize(entry1)
      assert {:ok, entry2} = Parser.parse(serialized)

      assert entry1.title == entry2.title
      assert entry1.entry_type == entry2.entry_type
      assert entry1.tags == entry2.tags
      assert entry1.body == entry2.body
      assert entry1.metadata["author"] == entry2.metadata["author"]
    end

    test "round-trip with body only content" do
      content = "Simple text without frontmatter."

      assert {:ok, entry1} = Parser.parse(content)
      serialized = Parser.serialize(entry1)
      assert {:ok, entry2} = Parser.parse(serialized)

      assert entry1.body == entry2.body
      assert entry2.metadata == %{}
    end
  end
end
