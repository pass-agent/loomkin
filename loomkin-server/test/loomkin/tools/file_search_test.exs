defmodule Loomkin.Tools.FileSearchTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FileSearch

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    # Create a directory structure
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.mkdir_p!(Path.join(tmp_dir, ".git/objects"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\nend\n")
    File.write!(Path.join(tmp_dir, "lib/helper.ex"), "defmodule Helper do\nend\n")
    File.write!(Path.join(tmp_dir, "test/app_test.exs"), "test\n")
    File.write!(Path.join(tmp_dir, ".git/objects/abc"), "blob\n")
    File.write!(Path.join(tmp_dir, "mix.exs"), "project\n")

    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert FileSearch.name() == "file_search"
    assert is_binary(FileSearch.description())
  end

  @tag :tmp_dir
  test "finds files matching glob pattern", %{project_path: proj} do
    params = %{"pattern" => "**/*.ex"}
    assert {:ok, %{result: result}} = FileSearch.run(params, %{project_path: proj})
    assert result =~ "app.ex"
    assert result =~ "helper.ex"
    refute result =~ "app_test.exs"
  end

  @tag :tmp_dir
  test "finds files in subdirectory", %{project_path: proj} do
    params = %{"pattern" => "*.exs", "path" => "test"}
    assert {:ok, %{result: result}} = FileSearch.run(params, %{project_path: proj})
    assert result =~ "app_test.exs"
  end

  @tag :tmp_dir
  test "excludes .git directory", %{project_path: proj} do
    params = %{"pattern" => "**/*"}
    assert {:ok, %{result: result}} = FileSearch.run(params, %{project_path: proj})
    refute result =~ ".git"
  end

  @tag :tmp_dir
  test "returns message when no files match", %{project_path: proj} do
    params = %{"pattern" => "**/*.rs"}
    assert {:ok, %{result: result}} = FileSearch.run(params, %{project_path: proj})
    assert result =~ "No files matched"
  end
end
