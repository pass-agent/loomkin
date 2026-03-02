defmodule Loomkin.Tools.ContentSearchTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.ContentSearch

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), """
    defmodule App do
      def hello do
        :world
      end

      def goodbye do
        :moon
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/helper.ex"), """
    defmodule Helper do
      def hello do
        :helper
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "notes.txt"), "not an elixir file\n")

    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert ContentSearch.name() == "content_search"
    assert is_binary(ContentSearch.description())
  end

  @tag :tmp_dir
  test "finds matching lines across files", %{project_path: proj} do
    params = %{"pattern" => "def hello"}
    assert {:ok, %{result: result}} = ContentSearch.run(params, %{project_path: proj})
    assert result =~ "app.ex"
    assert result =~ "helper.ex"
    assert result =~ "def hello"
  end

  @tag :tmp_dir
  test "filters by glob", %{project_path: proj} do
    params = %{"pattern" => "def hello", "glob" => "*.ex"}
    assert {:ok, %{result: result}} = ContentSearch.run(params, %{project_path: proj})
    assert result =~ "app.ex"
    refute result =~ "notes.txt"
  end

  @tag :tmp_dir
  test "searches in subdirectory", %{project_path: proj} do
    params = %{"pattern" => "defmodule", "path" => "lib"}
    assert {:ok, %{result: result}} = ContentSearch.run(params, %{project_path: proj})
    assert result =~ "App"
    assert result =~ "Helper"
  end

  @tag :tmp_dir
  test "returns no matches message", %{project_path: proj} do
    params = %{"pattern" => "NONEXISTENT_STRING_XYZ"}
    assert {:ok, %{result: result}} = ContentSearch.run(params, %{project_path: proj})
    assert result =~ "No matches"
  end

  @tag :tmp_dir
  test "returns error for invalid regex", %{project_path: proj} do
    params = %{"pattern" => "[invalid"}
    assert {:error, msg} = ContentSearch.run(params, %{project_path: proj})
    assert msg =~ "Invalid regex"
  end

  @tag :tmp_dir
  test "includes line numbers", %{project_path: proj} do
    params = %{"pattern" => "goodbye"}
    assert {:ok, %{result: result}} = ContentSearch.run(params, %{project_path: proj})
    # "def goodbye" is on line 6 of app.ex
    assert result =~ ":6:"
  end
end
