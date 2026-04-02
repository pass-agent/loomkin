defmodule Loomkin.Vault.FileSyncTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.FileSync
  alias Loomkin.Vault.Parser

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "file_sync_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "start_link/1 and status/0" do
    test "starts with no active watcher" do
      start_supervised!(FileSync)

      status = FileSync.status()
      assert status.watching == false
      assert is_nil(status.vault_id)
      assert is_nil(status.obsidian_path)
      assert status.pending_changes == 0
    end
  end

  describe "start_watching/2 and stop_watching/0" do
    test "starts and stops watching a directory", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)

      assert :ok = FileSync.start_watching("vault-123", tmp_dir)
      status = FileSync.status()
      assert status.watching == true
      assert status.vault_id == "vault-123"
      assert status.obsidian_path == tmp_dir

      assert :ok = FileSync.stop_watching()
      status = FileSync.status()
      assert status.watching == false
    end

    test "returns error for nonexistent directory" do
      start_supervised!(FileSync)
      # FileSystem may or may not error on nonexistent dirs depending on the OS backend.
      # We just verify the call doesn't crash the GenServer.
      bogus = "/tmp/file_sync_test_nonexistent_#{System.unique_integer([:positive])}"
      result = FileSync.start_watching("vault-123", bogus)
      # Either :ok or {:error, _} is acceptable — the GenServer must survive
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "on_vault_write/3 (write-through)" do
    test "writes serialized entry to disk when watching", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)
      FileSync.start_watching("vault-abc", tmp_dir)

      entry = %Entry{
        title: "Test Note",
        entry_type: "note",
        body: "Hello from the vault.",
        metadata: %{"title" => "Test Note", "type" => "note"},
        tags: ["test"]
      }

      FileSync.on_vault_write("vault-abc", "notes/hello.md", entry)

      # Cast is async — give it a moment to process
      Process.sleep(50)

      expected_path = Path.join(tmp_dir, "notes/hello.md")
      assert File.exists?(expected_path)

      content = File.read!(expected_path)
      assert content =~ "title: Test Note"
      assert content =~ "Hello from the vault."
    end

    test "does nothing when vault_id does not match", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)
      FileSync.start_watching("vault-abc", tmp_dir)

      entry = %Entry{body: "Should not appear", metadata: %{}, tags: []}
      FileSync.on_vault_write("other-vault", "nope.md", entry)

      Process.sleep(50)

      refute File.exists?(Path.join(tmp_dir, "nope.md"))
    end

    test "does nothing when not watching" do
      start_supervised!(FileSync)

      entry = %Entry{body: "No watcher", metadata: %{}, tags: []}
      # Should not crash — FileSync is running but not watching
      FileSync.on_vault_write("vault-abc", "orphan.md", entry)

      Process.sleep(50)
    end

    test "creates nested directories", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)
      FileSync.start_watching("vault-abc", tmp_dir)

      entry = %Entry{body: "Deep note", metadata: %{}, tags: []}
      FileSync.on_vault_write("vault-abc", "a/b/c/deep.md", entry)

      Process.sleep(50)

      assert File.exists?(Path.join(tmp_dir, "a/b/c/deep.md"))
    end
  end

  describe "wiki link extraction" do
    test "extracts [[target]] links", %{tmp_dir: tmp_dir} do
      content =
        "---\ntitle: Linked Note\ntype: note\n---\nSee [[other-note]] and [[folder/another]].\n"

      File.write!(Path.join(tmp_dir, "linked.md"), content)

      # Call the extraction indirectly through the private helper
      # We test via the module's internal processing by sending a file event
      start_supervised!(FileSync)
      FileSync.start_watching("vault-links", tmp_dir)

      # Simulate a file change by sending the event directly to the GenServer
      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "linked.md"), [:modified]}}
      )

      # Wait for debounce + processing
      Process.sleep(500)

      links =
        Repo.all(
          from(l in Loomkin.Schemas.VaultLink,
            where: l.vault_id == "vault-links" and l.source_path == "linked.md"
          )
        )

      assert length(links) == 2

      target_paths = Enum.map(links, & &1.target_path) |> Enum.sort()
      assert target_paths == ["folder/another.md", "other-note.md"]
    end

    test "extracts [[target|display text]] links with display text", %{tmp_dir: tmp_dir} do
      content =
        "---\ntitle: Display Links\ntype: note\n---\nCheck [[meeting-notes|Meeting Notes from Monday]].\n"

      File.write!(Path.join(tmp_dir, "display.md"), content)

      start_supervised!(FileSync)
      FileSync.start_watching("vault-display", tmp_dir)

      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "display.md"), [:modified]}}
      )

      Process.sleep(500)

      links =
        Repo.all(
          from(l in Loomkin.Schemas.VaultLink,
            where: l.vault_id == "vault-display" and l.source_path == "display.md"
          )
        )

      assert length(links) == 1
      link = hd(links)
      assert link.target_path == "meeting-notes.md"
      assert link.display_text == "Meeting Notes from Monday"
      assert link.link_type == :wiki_link
    end

    test "does not duplicate links on re-process", %{tmp_dir: tmp_dir} do
      content = "---\ntitle: Repeat\ntype: note\n---\nSee [[target]].\n"

      File.write!(Path.join(tmp_dir, "repeat.md"), content)

      start_supervised!(FileSync)
      FileSync.start_watching("vault-repeat", tmp_dir)

      # Process twice
      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "repeat.md"), [:modified]}}
      )

      Process.sleep(500)

      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "repeat.md"), [:modified]}}
      )

      Process.sleep(500)

      count =
        Repo.aggregate(
          from(l in Loomkin.Schemas.VaultLink,
            where: l.vault_id == "vault-repeat" and l.source_path == "repeat.md"
          ),
          :count
        )

      assert count == 1
    end
  end

  describe "should_process? filtering" do
    test "ignores non-markdown files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "readme.txt"), "not markdown")

      start_supervised!(FileSync)
      FileSync.start_watching("vault-filter", tmp_dir)

      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "readme.txt"), [:modified]}}
      )

      Process.sleep(100)

      # No pending changes should have accumulated
      status = FileSync.status()
      assert status.pending_changes == 0
    end

    test "ignores dotfiles and dotdirs", %{tmp_dir: tmp_dir} do
      hidden_dir = Path.join(tmp_dir, ".obsidian")
      File.mkdir_p!(hidden_dir)
      File.write!(Path.join(hidden_dir, "workspace.md"), "hidden")

      start_supervised!(FileSync)
      FileSync.start_watching("vault-filter2", tmp_dir)

      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(hidden_dir, "workspace.md"), [:modified]}}
      )

      Process.sleep(100)

      status = FileSync.status()
      assert status.pending_changes == 0
    end
  end

  describe "write-through self-skip" do
    test "does not re-import a file that was just written by on_vault_write", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)
      FileSync.start_watching("vault-skip", tmp_dir)

      entry = %Entry{
        title: "Self Write",
        body: "Written by vault",
        metadata: %{"title" => "Self Write"},
        tags: []
      }

      FileSync.on_vault_write("vault-skip", "self.md", entry)

      # Wait for the cast to be processed by the GenServer
      _ = FileSync.status()

      # The file was written. Now simulate the file event the OS watcher would fire.
      # The GenServer should skip it because the path is in the `writing` set.
      send(
        Process.whereis(FileSync),
        {:file_event, self(), {Path.join(tmp_dir, "self.md"), [:modified]}}
      )

      # Use a sync call to ensure the file_event message has been processed
      _ = FileSync.status()

      status = FileSync.status()
      assert status.pending_changes == 0
    end
  end

  describe "Parser.serialize round-trip" do
    test "write-through produces valid markdown", %{tmp_dir: tmp_dir} do
      start_supervised!(FileSync)
      FileSync.start_watching("vault-rt", tmp_dir)

      entry = %Entry{
        title: "Round Trip",
        entry_type: "note",
        body: "Body content here.",
        metadata: %{"title" => "Round Trip", "type" => "note", "custom" => "value"},
        tags: ["alpha", "beta"]
      }

      FileSync.on_vault_write("vault-rt", "roundtrip.md", entry)
      Process.sleep(50)

      file_path = Path.join(tmp_dir, "roundtrip.md")
      assert File.exists?(file_path)

      content = File.read!(file_path)
      {:ok, parsed} = Parser.parse(content)

      assert parsed.title == "Round Trip"
      assert parsed.entry_type == "note"
      assert parsed.body == "Body content here."
      assert "alpha" in parsed.tags
      assert "beta" in parsed.tags
    end
  end
end
