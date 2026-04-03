defmodule Loomkin.Schemas.VaultConfigTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Schemas.VaultConfig

  @valid_attrs %{
    vault_id: "my-vault",
    name: "My Vault",
    description: "A test vault",
    metadata: %{"version" => 1}
  }

  describe "changeset/2" do
    test "valid with all required fields" do
      changeset = VaultConfig.changeset(%VaultConfig{}, @valid_attrs)
      assert changeset.valid?
    end

    test "valid with only required fields" do
      attrs = %{vault_id: "v1", name: "Vault One"}
      changeset = VaultConfig.changeset(%VaultConfig{}, attrs)
      assert changeset.valid?
    end

    test "invalid without vault_id" do
      attrs = Map.delete(@valid_attrs, :vault_id)
      changeset = VaultConfig.changeset(%VaultConfig{}, attrs)
      refute changeset.valid?
      assert %{vault_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without name" do
      attrs = Map.delete(@valid_attrs, :name)
      changeset = VaultConfig.changeset(%VaultConfig{}, attrs)
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "persists to database" do
      {:ok, config} =
        %VaultConfig{}
        |> VaultConfig.changeset(@valid_attrs)
        |> Repo.insert()

      assert config.id
      assert config.vault_id == "my-vault"
      assert config.name == "My Vault"
      assert config.inserted_at
    end

    test "enforces unique constraint on vault_id" do
      {:ok, _} =
        %VaultConfig{}
        |> VaultConfig.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %VaultConfig{}
        |> VaultConfig.changeset(@valid_attrs)
        |> Repo.insert()

      assert %{vault_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "defaults metadata to empty map" do
      attrs = %{vault_id: "v3", name: "Third"}

      {:ok, config} =
        %VaultConfig{}
        |> VaultConfig.changeset(attrs)
        |> Repo.insert()

      assert config.metadata == %{}
    end
  end
end
