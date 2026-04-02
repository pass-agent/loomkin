defmodule Loomkin.Tools.VaultLinkTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultLink
  alias Loomkin.Vault

  setup do
    vault_id = "vault-link-test-#{System.unique_integer([:positive])}"

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_link_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: vault_id,
        name: "Link Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_dir}
      })

    # Seed two entries
    Vault.write(vault_id, "notes/source.md", "---\ntitle: Source\ntype: note\n---\nSource entry.")
    Vault.write(vault_id, "notes/target.md", "---\ntitle: Target\ntype: note\n---\nTarget entry.")

    %{vault_id: vault_id, tmp_dir: tmp_dir}
  end

  test "creates a link between entries", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/target.md",
      link_type: "related"
    }

    assert {:ok, %{result: result}} = VaultLink.run(params, %{})
    assert result =~ "Linked: notes/source.md -> notes/target.md (related)"

    link =
      Repo.get_by(Loomkin.Schemas.VaultLink,
        vault_id: vault_id,
        source_path: "notes/source.md",
        target_path: "notes/target.md"
      )

    assert link != nil
    assert link.link_type == :related
  end

  test "creates a wiki_link by default", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/target.md"
    }

    assert {:ok, %{result: result}} = VaultLink.run(params, %{})
    assert result =~ "(wiki_link)"
  end

  test "removes a link", %{vault_id: vault_id} do
    # Create first
    create_params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/target.md",
      link_type: "parent"
    }

    assert {:ok, _} = VaultLink.run(create_params, %{})

    # Remove
    remove_params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/target.md",
      link_type: "parent",
      remove: true
    }

    assert {:ok, %{result: result}} = VaultLink.run(remove_params, %{})
    assert result =~ "Removed"

    link =
      Repo.get_by(Loomkin.Schemas.VaultLink,
        vault_id: vault_id,
        source_path: "notes/source.md",
        target_path: "notes/target.md",
        link_type: :parent
      )

    assert link == nil
  end

  test "returns error for non-existent source", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      source_path: "notes/nonexistent.md",
      target_path: "notes/target.md"
    }

    assert {:error, msg} = VaultLink.run(params, %{})
    assert msg =~ "source entry not found"
  end

  test "returns error for non-existent target", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/nonexistent.md"
    }

    assert {:error, msg} = VaultLink.run(params, %{})
    assert msg =~ "target entry not found"
  end

  test "returns error for invalid link type", %{vault_id: vault_id} do
    params = %{
      vault_id: vault_id,
      source_path: "notes/source.md",
      target_path: "notes/target.md",
      link_type: "invalid_type"
    }

    assert {:error, msg} = VaultLink.run(params, %{})
    assert msg =~ "Invalid link_type"
  end
end
