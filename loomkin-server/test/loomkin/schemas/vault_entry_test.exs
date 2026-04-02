defmodule Loomkin.Schemas.VaultEntryTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Schemas.VaultEntry

  @valid_attrs %{
    vault_id: "my-vault",
    path: "notes/hello.md",
    title: "Hello",
    entry_type: "note",
    body: "# Hello\n\nWorld.",
    metadata: %{"author" => "alice"},
    tags: ["greeting", "test"],
    checksum: "abc123"
  }

  describe "changeset/2" do
    test "valid with all required fields" do
      changeset = VaultEntry.changeset(%VaultEntry{}, @valid_attrs)
      assert changeset.valid?
    end

    test "valid with only required fields" do
      attrs = %{vault_id: "v1", path: "a.md"}
      changeset = VaultEntry.changeset(%VaultEntry{}, attrs)
      assert changeset.valid?
    end

    test "invalid without vault_id" do
      attrs = Map.delete(@valid_attrs, :vault_id)
      changeset = VaultEntry.changeset(%VaultEntry{}, attrs)
      refute changeset.valid?
      assert %{vault_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without path" do
      attrs = Map.delete(@valid_attrs, :path)
      changeset = VaultEntry.changeset(%VaultEntry{}, attrs)
      refute changeset.valid?
      assert %{path: ["can't be blank"]} = errors_on(changeset)
    end

    test "persists to database" do
      {:ok, entry} =
        %VaultEntry{}
        |> VaultEntry.changeset(@valid_attrs)
        |> Repo.insert()

      assert entry.id
      assert entry.vault_id == "my-vault"
      assert entry.path == "notes/hello.md"
      assert entry.title == "Hello"
      assert entry.tags == ["greeting", "test"]
      assert entry.inserted_at
    end

    test "enforces unique constraint on [vault_id, path]" do
      {:ok, _} =
        %VaultEntry{}
        |> VaultEntry.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %VaultEntry{}
        |> VaultEntry.changeset(@valid_attrs)
        |> Repo.insert()

      assert %{vault_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same path in different vaults" do
      {:ok, _} =
        %VaultEntry{}
        |> VaultEntry.changeset(@valid_attrs)
        |> Repo.insert()

      other_vault_attrs = %{@valid_attrs | vault_id: "other-vault"}

      {:ok, entry} =
        %VaultEntry{}
        |> VaultEntry.changeset(other_vault_attrs)
        |> Repo.insert()

      assert entry.vault_id == "other-vault"
    end

    test "defaults metadata to empty map" do
      attrs = %{vault_id: "v1", path: "a.md"}

      {:ok, entry} =
        %VaultEntry{}
        |> VaultEntry.changeset(attrs)
        |> Repo.insert()

      assert entry.metadata == %{}
    end

    test "defaults tags to empty list" do
      attrs = %{vault_id: "v1", path: "a.md"}

      {:ok, entry} =
        %VaultEntry{}
        |> VaultEntry.changeset(attrs)
        |> Repo.insert()

      assert entry.tags == []
    end
  end
end
