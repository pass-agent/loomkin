defmodule Loomkin.RepoIntel.IndexTest do
  use ExUnit.Case, async: false

  alias Loomkin.RepoIntel.Index

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Create a small project structure
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.mkdir_p!(Path.join(tmp_dir, "node_modules"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), """
    defmodule App do
      def hello, do: :world
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/helper.ex"), """
    defmodule Helper do
      def assist, do: :ok
    end
    """)

    File.write!(Path.join(tmp_dir, "test/app_test.exs"), """
    defmodule AppTest do
      use ExUnit.Case
      test "hello" do
        assert App.hello() == :world
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Mix do end\n")
    File.write!(Path.join(tmp_dir, "README.md"), "# Test Project\n")
    File.write!(Path.join(tmp_dir, ".formatter.exs"), "[inputs: [\"lib/**/*.ex\"]]\n")

    # File inside .git should be skipped
    File.write!(Path.join(tmp_dir, ".git/config"), "gitconfig\n")

    # File inside node_modules should be skipped
    File.write!(Path.join(tmp_dir, "node_modules/pkg.js"), "module.exports = {}\n")

    # Use the globally-started Index (from Application supervisor) and point
    # it at the test's tmp_dir. This avoids killing the supervised process
    # (which could cause race conditions with other concurrent tests).
    pid = GenServer.whereis(Index) || elem(Index.start_link(), 1)
    Index.set_project(tmp_dir, pid)

    %{pid: pid, tmp_dir: tmp_dir}
  end

  test "build indexes files and skips .git, node_modules", %{pid: pid} do
    files = Index.list_files([], pid)
    paths = Enum.map(files, fn {path, _meta} -> path end)

    assert "lib/app.ex" in paths
    assert "lib/helper.ex" in paths
    assert "test/app_test.exs" in paths
    assert "mix.exs" in paths
    assert "README.md" in paths
    assert ".formatter.exs" in paths

    # Skipped directories
    refute Enum.any?(paths, &String.starts_with?(&1, ".git/"))
    refute Enum.any?(paths, &String.starts_with?(&1, "node_modules/"))
  end

  test "lookup returns file metadata", %{pid: pid} do
    assert {:ok, meta} = Index.lookup("lib/app.ex", pid)
    assert meta.type == :file
    assert meta.language == :elixir
    assert meta.size > 0
    assert %NaiveDateTime{} = meta.mtime
  end

  test "lookup returns :error for missing file", %{pid: pid} do
    assert :error = Index.lookup("nonexistent.ex", pid)
  end

  test "list_files filters by language", %{pid: pid} do
    elixir_files = Index.list_files([language: :elixir], pid)
    paths = Enum.map(elixir_files, fn {path, _} -> path end)

    assert "lib/app.ex" in paths
    assert "lib/helper.ex" in paths
    refute "README.md" in paths
  end

  test "list_files filters by pattern", %{pid: pid} do
    lib_files = Index.list_files([pattern: "lib/**/*.ex"], pid)
    paths = Enum.map(lib_files, fn {path, _} -> path end)

    assert "lib/app.ex" in paths
    assert "lib/helper.ex" in paths
    refute "test/app_test.exs" in paths
  end

  test "list_files filters by size", %{pid: pid} do
    # All our test files are small, so min_size: 1000 should return none
    big_files = Index.list_files([min_size: 1000], pid)
    assert big_files == []

    # min_size: 1 should return all files
    all_files = Index.list_files([min_size: 1], pid)
    assert length(all_files) > 0
  end

  test "stats returns correct counts", %{pid: pid} do
    stats = Index.stats(pid)

    assert stats.total_files > 0
    assert is_map(stats.by_language)
    assert stats.by_language[:elixir] >= 2
    assert stats.total_size > 0
  end

  test "refresh picks up new files", %{pid: pid, tmp_dir: tmp_dir} do
    # Add a new file
    File.write!(Path.join(tmp_dir, "lib/new_module.ex"), "defmodule New do end\n")

    Index.refresh(pid)

    assert {:ok, _meta} = Index.lookup("lib/new_module.ex", pid)
  end

  test "refresh removes deleted files", %{pid: pid, tmp_dir: tmp_dir} do
    assert {:ok, _} = Index.lookup("lib/helper.ex", pid)

    File.rm!(Path.join(tmp_dir, "lib/helper.ex"))
    Index.refresh(pid)

    assert :error = Index.lookup("lib/helper.ex", pid)
  end

  test "detect_language/1 maps extensions correctly" do
    assert Index.detect_language("app.ex") == :elixir
    assert Index.detect_language("test.exs") == :elixir
    assert Index.detect_language("index.js") == :javascript
    assert Index.detect_language("main.ts") == :typescript
    assert Index.detect_language("app.tsx") == :typescript
    assert Index.detect_language("script.py") == :python
    assert Index.detect_language("main.go") == :go
    assert Index.detect_language("lib.rs") == :rust
    assert Index.detect_language("app.rb") == :ruby
    assert Index.detect_language("README.md") == :markdown
    assert Index.detect_language("config.json") == :json
    assert Index.detect_language("config.toml") == :toml
    assert Index.detect_language("config.yaml") == :yaml
    assert Index.detect_language("config.yml") == :yaml
    assert Index.detect_language("random.xyz") == :unknown
  end
end
