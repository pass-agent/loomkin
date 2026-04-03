defmodule Loomkin.Vault.Validators.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Vault.Validators.Frontmatter

  describe "validate/1" do
    test "returns :ok when all required fields present for decision" do
      entry = %{
        entry_type: "decision",
        metadata: %{"id" => "d-001", "date" => "2026-04-01", "status" => "accepted"},
        path: "decisions/d-001.md"
      }

      assert Frontmatter.validate(entry) == :ok
    end

    test "returns :ok when all required fields present for meeting" do
      entry = %{
        entry_type: "meeting",
        metadata: %{"date" => "2026-04-01"},
        path: "meetings/standup.md"
      }

      assert Frontmatter.validate(entry) == :ok
    end

    test "detects missing 'date' in meeting" do
      entry = %{
        entry_type: "meeting",
        metadata: %{"attendees" => ["alice", "bob"]},
        path: "meetings/standup.md"
      }

      assert {:warn, info} = Frontmatter.validate(entry)
      assert info.path == "meetings/standup.md"
      assert info.type == "meeting"
      assert "date" in info.missing_fields
    end

    test "detects multiple missing fields in decision" do
      entry = %{
        entry_type: "decision",
        metadata: %{"id" => "d-002"},
        path: "decisions/d-002.md"
      }

      assert {:warn, info} = Frontmatter.validate(entry)
      assert "date" in info.missing_fields
      assert "status" in info.missing_fields
      refute "id" in info.missing_fields
    end

    test "returns :ok for types with no required fields" do
      entry = %{
        entry_type: "note",
        metadata: %{"title" => "My Note"},
        path: "notes/my-note.md"
      }

      assert Frontmatter.validate(entry) == :ok
    end

    test "returns :ok for unknown entry type" do
      entry = %{
        entry_type: "custom_type",
        metadata: %{},
        path: "custom/entry.md"
      }

      assert Frontmatter.validate(entry) == :ok
    end

    test "returns :ok for nil metadata" do
      entry = %{entry_type: "decision", metadata: nil, path: "decisions/d-003.md"}
      assert Frontmatter.validate(entry) == :ok
    end

    test "returns :ok for nil type" do
      entry = %{entry_type: nil, metadata: %{}, path: "unknown.md"}
      assert Frontmatter.validate(entry) == :ok
    end

    test "returns :ok for missing entry_type key" do
      entry = %{metadata: %{}, path: "unknown.md"}
      assert Frontmatter.validate(entry) == :ok
    end

    test "detects missing fields for checkin" do
      entry = %{
        entry_type: "checkin",
        metadata: %{"mood" => "good"},
        path: "checkins/2026-04-01.md"
      }

      assert {:warn, info} = Frontmatter.validate(entry)
      assert "date" in info.missing_fields
      assert "author" in info.missing_fields
    end

    test "detects missing fields for okr" do
      entry = %{
        entry_type: "okr",
        metadata: %{"cycle" => "Q2"},
        path: "okrs/q2.md"
      }

      assert {:warn, info} = Frontmatter.validate(entry)
      assert "scope" in info.missing_fields
      assert "status" in info.missing_fields
      refute "cycle" in info.missing_fields
    end

    test "detects missing role for person" do
      entry = %{
        entry_type: "person",
        metadata: %{"name" => "Alice"},
        path: "people/alice.md"
      }

      assert {:warn, info} = Frontmatter.validate(entry)
      assert info.missing_fields == ["role"]
    end
  end
end
