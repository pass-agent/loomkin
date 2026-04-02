defmodule Loomkin.Tools.VaultAuditTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultEntry
  alias Loomkin.Schemas.VaultLink
  alias Loomkin.Tools.VaultAudit
  alias Loomkin.Vault

  @vault_id "vault-audit-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_audit_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Audit Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    %{root: tmp_root}
  end

  describe "links check" do
    test "detects broken links" do
      # Create an entry
      Vault.write(
        @vault_id,
        "notes/source.md",
        "---\ntitle: Source\ntype: note\n---\nLinks to target"
      )

      # Create a link to a non-existent target
      %VaultLink{}
      |> VaultLink.changeset(%{
        vault_id: @vault_id,
        source_path: "notes/source.md",
        target_path: "notes/missing.md",
        link_type: :wiki_link
      })
      |> Repo.insert!()

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "links"}, %{})

      assert result =~ "Broken link"
      assert result =~ "notes/source.md"
      assert result =~ "notes/missing.md"
    end

    test "detects orphan entries" do
      Vault.write(
        @vault_id,
        "notes/orphan.md",
        "---\ntitle: Orphan\ntype: note\n---\nNo one links here"
      )

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "links"}, %{})

      assert result =~ "Orphan entry"
      assert result =~ "notes/orphan.md"
    end
  end

  describe "temporal check" do
    test "detects temporal language in evergreen entries" do
      Vault.write(
        @vault_id,
        "notes/evergreen.md",
        "---\ntitle: Evergreen Note\ntype: note\n---\nWe will soon implement this feature and currently it is broken"
      )

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "temporal"}, %{})

      assert result =~ "Temporal language"
      assert result =~ "will"
      assert result =~ "soon"
      assert result =~ "currently"
    end

    test "ignores non-evergreen entries" do
      Vault.write(
        @vault_id,
        "meetings/standup.md",
        "---\ntitle: Standup\ntype: meeting\ndate: 2026-04-01\n---\nWe will discuss this soon"
      )

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "temporal"}, %{})

      assert result =~ "all clear"
    end
  end

  describe "frontmatter check" do
    test "reports missing frontmatter fields" do
      # Decision missing required fields (id, date, status)
      %VaultEntry{}
      |> VaultEntry.changeset(%{
        vault_id: @vault_id,
        path: "decisions/bad.md",
        title: "Bad Decision",
        entry_type: "decision",
        body: "Some decision",
        metadata: %{}
      })
      |> Repo.insert!()

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "frontmatter"}, %{})

      assert result =~ "Missing frontmatter"
      assert result =~ "decisions/bad.md"
      assert result =~ "id"
      assert result =~ "date"
      assert result =~ "status"
    end

    test "passes when all required fields present" do
      %VaultEntry{}
      |> VaultEntry.changeset(%{
        vault_id: @vault_id,
        path: "decisions/good.md",
        title: "Good Decision",
        entry_type: "decision",
        body: "A well-formed decision",
        metadata: %{"id" => "DEC-001", "date" => "2026-04-01", "status" => "accepted"}
      })
      |> Repo.insert!()

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "frontmatter"}, %{})

      assert result =~ "all clear"
    end
  end

  describe "structure check" do
    test "detects type-directory mismatch" do
      %VaultEntry{}
      |> VaultEntry.changeset(%{
        vault_id: @vault_id,
        path: "random/misplaced.md",
        title: "Misplaced Meeting",
        entry_type: "meeting",
        body: "This meeting is in the wrong dir"
      })
      |> Repo.insert!()

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "structure"}, %{})

      assert result =~ "Structure mismatch"
      assert result =~ "random/misplaced.md"
      assert result =~ "meetings"
    end
  end

  describe "full audit" do
    test "returns clean report for healthy vault" do
      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id}, %{})

      assert result =~ "all clear"
    end

    test "runs all checks in full scope" do
      # Create a broken link
      Vault.write(
        @vault_id,
        "notes/linked.md",
        "---\ntitle: Linked\ntype: note\n---\nWe will do this soon"
      )

      %VaultLink{}
      |> VaultLink.changeset(%{
        vault_id: @vault_id,
        source_path: "notes/linked.md",
        target_path: "notes/gone.md",
        link_type: :wiki_link
      })
      |> Repo.insert!()

      # Create a decision with missing frontmatter
      %VaultEntry{}
      |> VaultEntry.changeset(%{
        vault_id: @vault_id,
        path: "decisions/incomplete.md",
        title: "Incomplete",
        entry_type: "decision",
        body: "Missing fields",
        metadata: %{}
      })
      |> Repo.insert!()

      assert {:ok, %{result: result}} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "full"}, %{})

      assert result =~ "Vault Audit Report"
      # Should find broken link (critical)
      assert result =~ "Broken link"
      # Should find temporal language (warning)
      assert result =~ "Temporal language"
      # Should find missing frontmatter (warning)
      assert result =~ "Missing frontmatter"
    end
  end

  describe "error handling" do
    test "returns error for unknown scope" do
      assert {:error, msg} =
               VaultAudit.run(%{vault_id: @vault_id, scope: "invalid"}, %{})

      assert msg =~ "Unknown scope"
    end
  end
end
