defmodule Loomkin.Tools.VaultCreateEntryTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultCreateEntry
  alias Loomkin.Vault

  setup do
    vault_id = "vault-create-entry-test-#{System.unique_integer([:positive])}"

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_create_entry_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: vault_id,
        name: "Create Entry Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_dir}
      })

    %{vault_id: vault_id, tmp_dir: tmp_dir}
  end

  test "creates a note entry with correct path resolution", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Twitter Strategy",
      entry_type: "note",
      content: "Some thoughts on Twitter.",
      tags: ["strategy", "content"]
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "Created note: \"Twitter Strategy\""
    assert result =~ "Path: notes/twitter-strategy.md"
    assert result =~ "Tags: strategy, content"

    assert {:ok, entry} = Vault.read(vault_id, "notes/twitter-strategy.md")
    assert entry.title == "Twitter Strategy"
    assert entry.entry_type == "note"
    assert entry.tags == ["strategy", "content"]
    assert entry.body == "Some thoughts on Twitter."
  end

  test "creates a meeting entry with date", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Sprint Planning",
      entry_type: "meeting",
      content: "Discussed priorities.",
      entry_date: "2026-04-01"
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "Path: meetings/2026-04-01-sprint-planning.md"

    assert {:ok, entry} = Vault.read(vault_id, "meetings/2026-04-01-sprint-planning.md")
    assert entry.title == "Sprint Planning"
    assert entry.metadata["date"] == "2026-04-01"
  end

  test "creates a decision entry with auto-incremented DR number", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Use Postgres",
      entry_type: "decision",
      content: "We decided to use Postgres.",
      entry_date: "2026-04-01"
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "DR-2026-001"
    assert result =~ "Path: decisions/DR-2026-001-use-postgres.md"

    # Second decision in the same year should increment
    params2 = %{
      vault_id: vault_id,
      title: "Use Redis",
      entry_type: "decision",
      content: "We decided to use Redis for caching.",
      entry_date: "2026-04-02"
    }

    assert {:ok, %{result: result2}} = VaultCreateEntry.run(params2, %{})
    assert result2 =~ "DR-2026-002"
  end

  test "rejects duplicate paths", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Unique Note",
      entry_type: "note",
      content: "First version."
    }

    assert {:ok, _} = VaultCreateEntry.run(params, %{})
    assert {:error, msg} = VaultCreateEntry.run(params, %{})
    assert msg =~ "already exists"
    assert msg =~ "vault_update_entry"
  end

  test "creates links when parent_path provided", %{vault_id: vault_id} do
    # Create a parent entry first
    Vault.write(
      vault_id,
      "topics/content.md",
      "---\ntitle: Content\ntype: topic\n---\nContent topic"
    )

    params = %{
      vault_id: vault_id,
      title: "Blog Ideas",
      entry_type: "note",
      content: "Some blog ideas.",
      parent_path: "topics/content.md"
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "topics/content.md (parent)"

    # Verify the link was created in DB
    link =
      Repo.get_by(Loomkin.Schemas.VaultLink,
        vault_id: vault_id,
        source_path: "notes/blog-ideas.md",
        target_path: "topics/content.md"
      )

    assert link != nil
    assert link.link_type == :parent
  end

  test "creates entry with extra_frontmatter", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Weekly Review",
      entry_type: "note",
      content: "Review content.",
      extra_frontmatter: Jason.encode!(%{"priority" => "high", "reviewer" => "alice"})
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "Created note"

    assert {:ok, entry} = Vault.read(vault_id, "notes/weekly-review.md")
    assert entry.metadata["priority"] == "high"
    assert entry.metadata["reviewer"] == "alice"
  end

  test "requires entry_date for meeting type", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Standup",
      entry_type: "meeting",
      content: "Notes."
    }

    assert {:error, msg} = VaultCreateEntry.run(params, %{})
    assert msg =~ "entry_date"
  end

  test "requires author for checkin type", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Checkin",
      entry_type: "checkin",
      content: "Daily update.",
      entry_date: "2026-04-01"
    }

    assert {:error, msg} = VaultCreateEntry.run(params, %{})
    assert msg =~ "author"
  end

  test "creates checkin with author and date", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      title: "Checkin",
      entry_type: "checkin",
      content: "Daily update.",
      entry_date: "2026-04-01",
      author: "alice"
    }

    assert {:ok, %{result: result}} = VaultCreateEntry.run(params, %{})
    assert result =~ "Path: updates/alice/2026-04-01.md"
  end
end
