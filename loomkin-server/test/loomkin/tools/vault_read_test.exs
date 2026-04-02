defmodule Loomkin.Tools.VaultReadTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultRead
  alias Loomkin.Vault

  @vault_id "vault-read-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_read_tool_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Read Tool Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    %{root: tmp_root}
  end

  test "reads an existing entry", %{root: _root} do
    Vault.write(@vault_id, "notes/test.md", "---\ntitle: Test\ntype: note\n---\nHello world")

    assert {:ok, %{result: result}} =
             VaultRead.run(%{vault_id: @vault_id, path: "notes/test.md"}, %{})

    assert result =~ "Test"
    assert result =~ "note"
  end

  test "returns error for missing entry" do
    assert {:error, msg} = VaultRead.run(%{vault_id: @vault_id, path: "nope.md"}, %{})
    assert msg =~ "not found"
  end

  test "returns error for missing vault" do
    assert {:error, msg} = VaultRead.run(%{vault_id: "nonexistent", path: "x.md"}, %{})
    assert msg =~ "not found"
  end
end
