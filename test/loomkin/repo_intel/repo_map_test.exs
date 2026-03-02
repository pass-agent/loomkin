defmodule Loomkin.RepoIntel.RepoMapTest do
  use ExUnit.Case, async: true

  alias Loomkin.RepoIntel.RepoMap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Create test source files with known patterns
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/example.ex"), """
    defmodule MyApp.Example do
      defstruct [:name, :value]

      defmacro my_macro(arg) do
        quote do: unquote(arg)
      end

      def public_fun(x), do: x + 1

      defp private_fun(x), do: x - 1
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/app.py"), """
    class UserService:
        def __init__(self):
            pass

    def helper_function():
        return True

    class AdminService:
        pass
    """)

    File.write!(Path.join(tmp_dir, "lib/app.js"), """
    export function fetchData(url) {
      return fetch(url);
    }

    export class ApiClient {
      constructor() {}
    }

    export const API_BASE = "https://api.example.com";

    async function processData(data) {
      return data;
    }
    """)

    File.write!(Path.join(tmp_dir, "lib/main.go"), """
    package main

    func main() {
        fmt.Println("hello")
    }

    type Config struct {
        Name string
    }

    func (c *Config) Validate() error {
        return nil
    }
    """)

    %{tmp_dir: tmp_dir}
  end

  describe "extract_symbols/1" do
    test "extracts Elixir symbols", %{tmp_dir: tmp_dir} do
      symbols = RepoMap.extract_symbols(Path.join(tmp_dir, "lib/example.ex"))

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "MyApp.Example" in names
      assert "public_fun" in names
      assert "private_fun" in names
      assert "my_macro" in names
      assert :module in types
      assert :function in types
      assert :struct in types
      assert :macro in types

      # Verify line numbers are present
      Enum.each(symbols, fn sym ->
        assert is_integer(sym.line)
        assert sym.line > 0
      end)
    end

    test "extracts Python symbols", %{tmp_dir: tmp_dir} do
      symbols = RepoMap.extract_symbols(Path.join(tmp_dir, "lib/app.py"))

      names = Enum.map(symbols, & &1.name)

      assert "UserService" in names
      assert "AdminService" in names
      assert "helper_function" in names
    end

    test "extracts JavaScript symbols", %{tmp_dir: tmp_dir} do
      symbols = RepoMap.extract_symbols(Path.join(tmp_dir, "lib/app.js"))

      names = Enum.map(symbols, & &1.name)

      assert "fetchData" in names
      assert "ApiClient" in names
      assert "API_BASE" in names
      assert "processData" in names
    end

    test "extracts Go symbols", %{tmp_dir: tmp_dir} do
      symbols = RepoMap.extract_symbols(Path.join(tmp_dir, "lib/main.go"))

      names = Enum.map(symbols, & &1.name)

      assert "main" in names
      assert "Config" in names
      assert "Validate" in names
    end

    test "returns empty list for nonexistent file" do
      assert RepoMap.extract_symbols("/nonexistent/file.ex") == []
    end

    test "returns empty list for unsupported language", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "data.csv"), "a,b,c\n1,2,3\n")
      assert RepoMap.extract_symbols(Path.join(tmp_dir, "data.csv")) == []
    end
  end

  describe "rank_files/2" do
    test "mentioned files get highest scores" do
      entries = [
        {"lib/app.ex", %{language: :elixir, size: 100}},
        {"lib/helper.ex", %{language: :elixir, size: 50}},
        {"README.md", %{language: :markdown, size: 200}}
      ]

      ranked = RepoMap.rank_files(entries, mentioned_files: ["lib/helper.ex"])

      # The mentioned file should be first
      {top_path, _meta, _score} = hd(ranked)
      assert top_path == "lib/helper.ex"
    end

    test "keyword matching boosts score" do
      entries = [
        {"lib/auth.ex", %{language: :elixir, size: 100}},
        {"lib/database.ex", %{language: :elixir, size: 100}},
        {"README.md", %{language: :markdown, size: 200}}
      ]

      ranked = RepoMap.rank_files(entries, keywords: ["auth"])

      {top_path, _meta, _score} = hd(ranked)
      assert top_path == "lib/auth.ex"
    end

    test "lib files rank higher than other files" do
      entries = [
        {"config/config.toml", %{language: :toml, size: 50}},
        {"lib/core.ex", %{language: :elixir, size: 100}}
      ]

      ranked = RepoMap.rank_files(entries)

      {top_path, _meta, _score} = hd(ranked)
      assert top_path == "lib/core.ex"
    end
  end
end
