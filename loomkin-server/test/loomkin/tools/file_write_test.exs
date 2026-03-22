defmodule Loomkin.Tools.FileWriteTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FileWrite

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert FileWrite.name() == "file_write"
    assert is_binary(FileWrite.description())
  end

  @tag :tmp_dir
  test "writes a new file", %{project_path: proj} do
    params = %{"file_path" => "hello.txt", "content" => "Hello, world!"}
    assert {:ok, %{result: msg}} = FileWrite.run(params, %{project_path: proj})
    assert msg =~ "13 bytes"
    assert File.read!(Path.join(proj, "hello.txt")) == "Hello, world!"
  end

  @tag :tmp_dir
  test "creates parent directories", %{project_path: proj} do
    params = %{"file_path" => "a/b/c/deep.txt", "content" => "deep"}
    assert {:ok, %{result: _msg}} = FileWrite.run(params, %{project_path: proj})
    assert File.exists?(Path.join(proj, "a/b/c/deep.txt"))
  end

  @tag :tmp_dir
  test "overwrites existing file", %{project_path: proj} do
    path = Path.join(proj, "overwrite.txt")
    File.write!(path, "original")

    params = %{"file_path" => "overwrite.txt", "content" => "replaced"}
    assert {:ok, %{result: _}} = FileWrite.run(params, %{project_path: proj})
    assert File.read!(path) == "replaced"
  end

  @tag :tmp_dir
  test "rejects path traversal", %{project_path: proj} do
    params = %{"file_path" => "../escape.txt", "content" => "bad"}
    assert {:error, msg} = FileWrite.run(params, %{project_path: proj})
    assert msg =~ "outside the project directory"
  end
end
