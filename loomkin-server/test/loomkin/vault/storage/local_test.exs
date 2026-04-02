defmodule Loomkin.Vault.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias Loomkin.Vault.Storage.Local

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_local_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    %{opts: [root: tmp_root], root: tmp_root}
  end

  describe "put/3" do
    test "writes content to a file", %{opts: opts, root: root} do
      assert :ok = Local.put("notes/hello.md", "# Hello", opts)
      assert File.read!(Path.join(root, "notes/hello.md")) == "# Hello"
    end

    test "creates intermediate directories automatically", %{opts: opts, root: root} do
      assert :ok = Local.put("deep/nested/dir/file.md", "content", opts)
      assert File.exists?(Path.join(root, "deep/nested/dir/file.md"))
    end

    test "overwrites existing files", %{opts: opts} do
      Local.put("overwrite.md", "v1", opts)
      assert :ok = Local.put("overwrite.md", "v2", opts)
      assert {:ok, "v2"} = Local.get("overwrite.md", opts)
    end
  end

  describe "get/2" do
    test "returns content of an existing file", %{opts: opts} do
      Local.put("readme.md", "# Readme", opts)
      assert {:ok, "# Readme"} = Local.get("readme.md", opts)
    end

    test "returns :not_found for missing files", %{opts: opts} do
      assert {:error, :not_found} = Local.get("does_not_exist.md", opts)
    end
  end

  describe "delete/2" do
    test "removes an existing file", %{opts: opts} do
      Local.put("to_delete.md", "bye", opts)
      assert :ok = Local.delete("to_delete.md", opts)
      assert {:error, :not_found} = Local.get("to_delete.md", opts)
    end

    test "is idempotent for missing files", %{opts: opts} do
      assert :ok = Local.delete("already_gone.md", opts)
    end
  end

  describe "exists?/2" do
    test "returns true for existing files", %{opts: opts} do
      Local.put("exists.md", "yes", opts)
      assert Local.exists?("exists.md", opts)
    end

    test "returns false for missing files", %{opts: opts} do
      refute Local.exists?("nope.md", opts)
    end
  end

  describe "list/2" do
    test "returns relative paths for all files under a prefix", %{opts: opts} do
      Local.put("project/a.md", "a", opts)
      Local.put("project/sub/b.md", "b", opts)
      Local.put("other/c.md", "c", opts)

      assert {:ok, files} = Local.list("project", opts)
      assert Enum.sort(files) == ["project/a.md", "project/sub/b.md"]
    end

    test "returns empty list for non-existent prefix", %{opts: opts} do
      assert {:ok, []} = Local.list("nonexistent", opts)
    end

    test "returns empty list for prefix that is a file, not a directory", %{opts: opts} do
      Local.put("single_file.md", "content", opts)
      assert {:ok, []} = Local.list("single_file.md", opts)
    end

    test "lists files at root level with empty prefix", %{opts: opts} do
      Local.put("root_file.md", "content", opts)
      Local.put("sub/nested.md", "nested", opts)

      assert {:ok, files} = Local.list("", opts)
      assert "root_file.md" in files
      assert "sub/nested.md" in files
    end
  end
end
