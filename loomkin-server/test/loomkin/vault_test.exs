defmodule Loomkin.VaultTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Vault
  alias Loomkin.Vault.Entry

  @vault_id "context-test-vault"

  setup do
    {:ok, config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Test Vault"
      })

    %{config: config}
  end

  describe "create_vault/1 and get_config/1" do
    test "creates and retrieves a vault config" do
      assert {:ok, config} = Vault.get_config(@vault_id)
      assert config.name == "Test Vault"
    end

    test "returns error for unknown vault" do
      assert {:error, :vault_not_found} = Vault.get_config("nonexistent")
    end
  end

  describe "write/3 and read/2" do
    test "round-trips raw markdown content" do
      content = """
      ---
      title: Round Trip
      type: note
      tags:
        - test
      ---
      This is a test note.
      """

      assert {:ok, entry} = Vault.write(@vault_id, "notes/round-trip.md", content)
      assert entry.title == "Round Trip"
      assert entry.entry_type == "note"
      assert "test" in entry.tags

      assert {:ok, read_entry} = Vault.read(@vault_id, "notes/round-trip.md")
      assert read_entry.title == "Round Trip"
      assert read_entry.body =~ "This is a test note."
    end

    test "writes an Entry struct" do
      entry = %Entry{
        title: "Struct Entry",
        entry_type: "decision",
        body: "We decided to use Elixir.",
        tags: ["arch"],
        metadata: %{}
      }

      assert {:ok, written} = Vault.write(@vault_id, "decisions/elixir.md", entry)
      assert written.title == "Struct Entry"
      assert written.entry_type == "decision"
    end

    test "returns :not_found for missing entry" do
      assert {:error, :not_found} = Vault.read(@vault_id, "nope.md")
    end
  end

  describe "write_entry/2" do
    test "writes using the entry's path field" do
      entry = %Entry{
        path: "meetings/standup.md",
        title: "Standup",
        entry_type: "meeting",
        body: "Discussed progress.",
        tags: [],
        metadata: %{}
      }

      assert {:ok, written} = Vault.write_entry(@vault_id, entry)
      assert written.title == "Standup"

      assert {:ok, read} = Vault.read(@vault_id, "meetings/standup.md")
      assert read.title == "Standup"
    end
  end

  describe "delete/2" do
    test "removes entry from index" do
      Vault.write(@vault_id, "to-delete.md", "---\ntitle: Delete Me\n---\nBody")

      assert {:ok, _} = Vault.read(@vault_id, "to-delete.md")

      assert :ok = Vault.delete(@vault_id, "to-delete.md")

      assert {:error, :not_found} = Vault.read(@vault_id, "to-delete.md")
    end
  end

  describe "search/3" do
    test "finds entries by full-text search" do
      Vault.write(@vault_id, "notes/elixir.md", """
      ---
      title: Elixir Guide
      type: note
      ---
      GenServer patterns and supervision trees.
      """)

      Vault.write(@vault_id, "notes/python.md", """
      ---
      title: Python Guide
      type: note
      ---
      Django and Flask frameworks.
      """)

      results = Vault.search(@vault_id, "elixir")
      assert length(results) >= 1
      paths = Enum.map(results, & &1.path)
      assert "notes/elixir.md" in paths
    end
  end

  describe "list/2" do
    test "lists all vault entries" do
      Vault.write(@vault_id, "a.md", "---\ntitle: A\n---\nA")
      Vault.write(@vault_id, "b.md", "---\ntitle: B\n---\nB")

      results = Vault.list(@vault_id)
      assert length(results) == 2
    end

    test "filters by entry_type" do
      Vault.write(@vault_id, "note.md", "---\ntitle: Note\ntype: note\n---\nContent")
      Vault.write(@vault_id, "meeting.md", "---\ntitle: Meeting\ntype: meeting\n---\nContent")

      results = Vault.list(@vault_id, entry_type: "note")
      assert length(results) == 1
      assert hd(results).entry_type == "note"
    end
  end

  describe "stats/1" do
    test "returns entry counts by type" do
      Vault.write(@vault_id, "n1.md", "---\ntitle: N1\ntype: note\n---\nContent")
      Vault.write(@vault_id, "n2.md", "---\ntitle: N2\ntype: note\n---\nContent")
      Vault.write(@vault_id, "m1.md", "---\ntitle: M1\ntype: meeting\n---\nContent")

      stats = Vault.stats(@vault_id)
      assert stats.total_entries == 3
      assert stats.by_type["note"] == 2
      assert stats.by_type["meeting"] == 1
    end
  end
end
