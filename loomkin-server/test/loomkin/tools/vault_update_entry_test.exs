defmodule Loomkin.Tools.VaultUpdateEntryTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultUpdateEntry
  alias Loomkin.Vault

  setup do
    vault_id = "vault-update-entry-test-#{System.unique_integer([:positive])}"

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_update_entry_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: vault_id,
        name: "Update Entry Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_dir}
      })

    # Seed an entry
    Vault.write(
      vault_id,
      "notes/existing.md",
      "---\ntitle: Existing Note\ntype: note\ntags:\n  - alpha\n  - beta\n---\nOriginal content."
    )

    %{vault_id: vault_id, tmp_dir: tmp_dir}
  end

  test "updates content", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      content: "Replaced content."
    }

    assert {:ok, %{result: result}} = VaultUpdateEntry.run(params, %{})
    assert result =~ "content replaced"

    assert {:ok, entry} = Vault.read(vault_id, "notes/existing.md")
    assert entry.body == "Replaced content."
  end

  test "appends to content", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      append: "Appended section."
    }

    assert {:ok, %{result: result}} = VaultUpdateEntry.run(params, %{})
    assert result =~ "content appended"

    assert {:ok, entry} = Vault.read(vault_id, "notes/existing.md")
    assert entry.body =~ "Original content."
    assert entry.body =~ "Appended section."
  end

  test "rejects content and append together", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      content: "New content",
      append: "More text"
    }

    assert {:error, msg} = VaultUpdateEntry.run(params, %{})
    assert msg =~ "mutually exclusive"
  end

  test "updates tags — add and remove", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      add_tags: ["gamma"],
      remove_tags: ["alpha"]
    }

    assert {:ok, %{result: result}} = VaultUpdateEntry.run(params, %{})
    assert result =~ "added tags: gamma"
    assert result =~ "removed tags: alpha"

    assert {:ok, entry} = Vault.read(vault_id, "notes/existing.md")
    assert "gamma" in entry.tags
    assert "beta" in entry.tags
    refute "alpha" in entry.tags
  end

  test "updates frontmatter", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      frontmatter_updates: Jason.encode!(%{"priority" => "high", "reviewed" => true})
    }

    assert {:ok, %{result: result}} = VaultUpdateEntry.run(params, %{})
    assert result =~ "frontmatter updated"

    assert {:ok, entry} = Vault.read(vault_id, "notes/existing.md")
    assert entry.metadata["priority"] == "high"
    assert entry.metadata["reviewed"] == true
  end

  test "updates status", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/existing.md",
      status: "archived"
    }

    assert {:ok, %{result: result}} = VaultUpdateEntry.run(params, %{})
    assert result =~ "status -> archived"

    assert {:ok, entry} = Vault.read(vault_id, "notes/existing.md")
    assert entry.metadata["status"] == "archived"
  end

  test "returns error for non-existent entry", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      path: "notes/does-not-exist.md",
      content: "New content"
    }

    assert {:error, msg} = VaultUpdateEntry.run(params, %{})
    assert msg =~ "not found"
  end
end
