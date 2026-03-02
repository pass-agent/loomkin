defmodule Loomkin.Tools.DirectoryListTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.DirectoryList

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "file_a.txt"), "hello")
    File.write!(Path.join(tmp_dir, "file_b.txt"), "world, longer content")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))

    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert DirectoryList.name() == "directory_list"
    assert is_binary(DirectoryList.description())
  end

  @tag :tmp_dir
  test "lists directory contents", %{project_path: proj} do
    params = %{"path" => "."}
    assert {:ok, %{result: result}} = DirectoryList.run(params, %{project_path: proj})
    assert result =~ "file_a.txt"
    assert result =~ "file_b.txt"
    assert result =~ "subdir/"
    assert result =~ "3 entries"
  end

  @tag :tmp_dir
  test "shows file type indicators", %{project_path: proj} do
    params = %{"path" => "."}
    assert {:ok, %{result: result}} = DirectoryList.run(params, %{project_path: proj})
    assert result =~ "file"
    assert result =~ "dir"
  end

  @tag :tmp_dir
  test "returns error for missing directory", %{project_path: proj} do
    params = %{"path" => "nonexistent"}
    assert {:error, msg} = DirectoryList.run(params, %{project_path: proj})
    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "rejects path traversal", %{project_path: proj} do
    params = %{"path" => "../.."}
    assert {:error, msg} = DirectoryList.run(params, %{project_path: proj})
    assert msg =~ "outside the project directory"
  end
end
