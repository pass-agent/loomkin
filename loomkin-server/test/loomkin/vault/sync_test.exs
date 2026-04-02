defmodule Loomkin.Vault.SyncTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Vault.Index
  alias Loomkin.Vault.Storage.Local
  alias Loomkin.Vault.Sync

  @vault_id "sync-test-vault"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_sync_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    %{opts: [root: tmp_root], root: tmp_root}
  end

  defp write_file(root, path, content) do
    full = Path.join(root, path)
    full |> Path.dirname() |> File.mkdir_p!()
    File.write!(full, content)
  end

  describe "full_sync/3" do
    test "syncs all markdown files from storage to index", %{opts: opts, root: root} do
      write_file(root, "notes/one.md", """
      ---
      title: First Note
      type: note
      tags:
        - alpha
      ---
      Body of the first note.
      """)

      write_file(root, "notes/two.md", """
      ---
      title: Second Note
      type: note
      ---
      Body of the second note.
      """)

      # Non-markdown file should be ignored
      write_file(root, "readme.txt", "not markdown")

      assert {:ok, result} = Sync.full_sync(@vault_id, Local, opts)
      assert result.synced == 2
      assert result.errors == []
      assert result.total == 2

      assert %{title: "First Note"} = Index.get(@vault_id, "notes/one.md")
      assert %{title: "Second Note"} = Index.get(@vault_id, "notes/two.md")
    end

    test "reports errors for unparseable files", %{opts: opts, root: root} do
      write_file(root, "good.md", """
      ---
      title: Good
      ---
      Content
      """)

      write_file(root, "bad.md", """
      ---
      : invalid yaml [[[
      ---
      Content
      """)

      assert {:ok, result} = Sync.full_sync(@vault_id, Local, opts)
      assert result.synced == 1
      assert length(result.errors) == 1
      assert {"bad.md", _reason} = hd(result.errors)
    end
  end

  describe "sync_entry/4" do
    test "syncs a single file to the index", %{opts: opts, root: root} do
      write_file(root, "notes/single.md", """
      ---
      title: Single Entry
      type: note
      ---
      Single body.
      """)

      assert {:ok, :synced} = Sync.sync_entry(@vault_id, "notes/single.md", Local, opts)
      assert %{title: "Single Entry"} = Index.get(@vault_id, "notes/single.md")
    end

    test "returns :unchanged when checksum matches", %{opts: opts, root: root} do
      content = """
      ---
      title: Cached
      ---
      Same content.
      """

      write_file(root, "cached.md", content)

      assert {:ok, :synced} = Sync.sync_entry(@vault_id, "cached.md", Local, opts)
      assert {:ok, :unchanged} = Sync.sync_entry(@vault_id, "cached.md", Local, opts)
    end

    test "re-syncs when content changes", %{opts: opts, root: root} do
      write_file(root, "changing.md", """
      ---
      title: Version 1
      ---
      Old body.
      """)

      assert {:ok, :synced} = Sync.sync_entry(@vault_id, "changing.md", Local, opts)
      assert %{title: "Version 1"} = Index.get(@vault_id, "changing.md")

      write_file(root, "changing.md", """
      ---
      title: Version 2
      ---
      New body.
      """)

      assert {:ok, :synced} = Sync.sync_entry(@vault_id, "changing.md", Local, opts)
      assert %{title: "Version 2"} = Index.get(@vault_id, "changing.md")
    end

    test "returns error for missing file", %{opts: opts} do
      assert {:error, "missing.md", :not_found} =
               Sync.sync_entry(@vault_id, "missing.md", Local, opts)
    end
  end

  describe "remove_entry/2" do
    test "deletes an indexed entry" do
      {:ok, _} =
        Index.upsert(%{vault_id: @vault_id, path: "to-remove.md", title: "Remove Me"})

      assert :ok = Sync.remove_entry(@vault_id, "to-remove.md")
      assert nil == Index.get(@vault_id, "to-remove.md")
    end

    test "returns error for non-existent entry" do
      assert {:error, :not_found} = Sync.remove_entry(@vault_id, "nope.md")
    end
  end

  describe "check_sync/3" do
    test "detects when storage and index are in sync", %{opts: opts, root: root} do
      write_file(root, "synced.md", """
      ---
      title: Synced
      ---
      Body.
      """)

      Sync.full_sync(@vault_id, Local, opts)

      assert {:ok, status} = Sync.check_sync(@vault_id, Local, opts)
      assert status.in_sync
      assert status.storage_only == []
      assert status.index_only == []
      assert status.storage_count == 1
      assert status.index_count == 1
    end

    test "detects storage-only files", %{opts: opts, root: root} do
      write_file(root, "indexed.md", "# Indexed")
      Sync.full_sync(@vault_id, Local, opts)

      # Add a new file to storage only
      write_file(root, "new-file.md", "# New")

      assert {:ok, status} = Sync.check_sync(@vault_id, Local, opts)
      refute status.in_sync
      assert "new-file.md" in status.storage_only
    end

    test "detects index-only entries", %{opts: opts, root: root} do
      write_file(root, "will-delete.md", "# Will Delete")
      Sync.full_sync(@vault_id, Local, opts)

      # Remove file from storage but leave index
      File.rm!(Path.join(root, "will-delete.md"))

      assert {:ok, status} = Sync.check_sync(@vault_id, Local, opts)
      refute status.in_sync
      assert "will-delete.md" in status.index_only
    end
  end
end
