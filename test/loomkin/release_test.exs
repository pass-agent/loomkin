defmodule Loomkin.ReleaseTest do
  use ExUnit.Case, async: true

  describe "db_path/0" do
    test "returns a path string" do
      path = Loomkin.Release.db_path()
      assert is_binary(path)
      assert String.ends_with?(path, ".db")
    end
  end

  describe "create_db/0" do
    test "ensures directory exists" do
      assert :ok = Loomkin.Release.create_db()
      db_dir = Path.dirname(Loomkin.Release.db_path())
      assert File.dir?(db_dir)
    end
  end

  describe "release config" do
    test "mix.exs defines loom release" do
      releases = Loomkin.MixProject.project()[:releases]
      assert releases != nil
      assert Keyword.has_key?(releases, :loomkin)

      loom_release = releases[:loomkin]
      assert :assemble in loom_release[:steps]
    end
  end
end
