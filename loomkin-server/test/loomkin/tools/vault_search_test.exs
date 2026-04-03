defmodule Loomkin.Tools.VaultSearchTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultSearch
  alias Loomkin.Vault

  @vault_id "vault-search-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_search_tool_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Search Tool Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    Vault.write(@vault_id, "notes/elixir.md", """
    ---
    title: Elixir Guide
    type: note
    tags:
      - elixir
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

    %{root: tmp_root}
  end

  test "finds matching entries" do
    assert {:ok, %{result: result}} =
             VaultSearch.run(%{vault_id: @vault_id, query: "elixir"}, %{})

    assert result =~ "Found"
    assert result =~ "notes/elixir.md"
  end

  test "returns no results message for unmatched query" do
    assert {:ok, %{result: result}} =
             VaultSearch.run(%{vault_id: @vault_id, query: "nonexistent_xyzzy"}, %{})

    assert result =~ "No entries found"
  end
end
