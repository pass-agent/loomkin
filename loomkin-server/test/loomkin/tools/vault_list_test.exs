defmodule Loomkin.Tools.VaultListTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultList
  alias Loomkin.Vault

  @vault_id "vault-list-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_list_tool_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "List Tool Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    Vault.write(@vault_id, "a.md", "---\ntitle: A\ntype: note\n---\nA")
    Vault.write(@vault_id, "b.md", "---\ntitle: B\ntype: meeting\n---\nB")

    %{root: tmp_root}
  end

  test "lists all entries" do
    assert {:ok, %{result: result}} = VaultList.run(%{vault_id: @vault_id}, %{})
    assert result =~ "2 entries"
    assert result =~ "a.md"
    assert result =~ "b.md"
  end

  test "filters by entry_type" do
    assert {:ok, %{result: result}} =
             VaultList.run(%{vault_id: @vault_id, entry_type: "note"}, %{})

    assert result =~ "1 entries"
    assert result =~ "a.md"
    refute result =~ "b.md"
  end

  test "returns empty message for vault with no entries" do
    {:ok, _} =
      Vault.create_vault(%{
        vault_id: "empty-vault",
        name: "Empty",
        storage_type: "local",
        storage_config: %{"root" => "/tmp/empty_#{System.unique_integer([:positive])}"}
      })

    assert {:ok, %{result: result}} = VaultList.run(%{vault_id: "empty-vault"}, %{})
    assert result =~ "empty"
  end
end
