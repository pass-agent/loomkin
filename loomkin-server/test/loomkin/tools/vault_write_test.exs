defmodule Loomkin.Tools.VaultWriteTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultWrite
  alias Loomkin.Vault

  @vault_id "vault-write-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_write_tool_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Write Tool Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    %{root: tmp_root}
  end

  test "writes content and returns confirmation", %{root: _root} do
    params = %{
      vault_id: @vault_id,
      path: "notes/new.md",
      content: "---\ntitle: New Note\ntype: note\n---\nContent here."
    }

    assert {:ok, %{result: result}} = VaultWrite.run(params, %{})
    assert result =~ "Written: notes/new.md"
    assert result =~ "New Note"

    assert {:ok, entry} = Vault.read(@vault_id, "notes/new.md")
    assert entry.title == "New Note"
  end

  test "writes to any vault_id without requiring config" do
    params = %{vault_id: "nonexistent", path: "x.md", content: "# Hello"}
    assert {:ok, %{result: result}} = VaultWrite.run(params, %{})
    assert result =~ "Written: x.md"
  end
end
