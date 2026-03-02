defmodule Loomkin.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FileRead

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    # Create a sample file with known content
    file = Path.join(tmp_dir, "sample.txt")

    content =
      1..20
      |> Enum.map(&"Line #{&1}")
      |> Enum.join("\n")

    File.write!(file, content)

    %{project_path: tmp_dir, sample_file: file}
  end

  test "action metadata is correct" do
    assert FileRead.name() == "file_read"
    assert is_binary(FileRead.description())
  end

  @tag :tmp_dir
  test "reads entire file with line numbers", %{project_path: proj} do
    params = %{"file_path" => "sample.txt"}
    assert {:ok, %{result: result}} = FileRead.run(params, %{project_path: proj})
    assert result =~ "20 lines total"
    assert result =~ "Line 1"
    assert result =~ "Line 20"
  end

  @tag :tmp_dir
  test "reads file with offset", %{project_path: proj} do
    params = %{"file_path" => "sample.txt", "offset" => 5}
    assert {:ok, %{result: result}} = FileRead.run(params, %{project_path: proj})
    assert result =~ "Line 5"
    assert result =~ "Line 20"
    refute result =~ "\tLine 4\n"
  end

  @tag :tmp_dir
  test "reads file with limit", %{project_path: proj} do
    params = %{"file_path" => "sample.txt", "limit" => 3}
    assert {:ok, %{result: result}} = FileRead.run(params, %{project_path: proj})
    assert result =~ "showing 3"
    assert result =~ "Line 1"
    assert result =~ "Line 3"
    refute result =~ "\tLine 4\n"
  end

  @tag :tmp_dir
  test "reads file with offset and limit", %{project_path: proj} do
    params = %{"file_path" => "sample.txt", "offset" => 10, "limit" => 3}
    assert {:ok, %{result: result}} = FileRead.run(params, %{project_path: proj})
    assert result =~ "showing 3"
    assert result =~ "Line 10"
    assert result =~ "Line 12"
    refute result =~ "\tLine 9\n"
    refute result =~ "\tLine 13\n"
  end

  @tag :tmp_dir
  test "returns error for missing file", %{project_path: proj} do
    params = %{"file_path" => "nonexistent.txt"}
    assert {:error, msg} = FileRead.run(params, %{project_path: proj})
    assert msg =~ "File not found"
  end

  @tag :tmp_dir
  test "rejects path traversal", %{project_path: proj} do
    params = %{"file_path" => "../../etc/passwd"}
    assert {:error, msg} = FileRead.run(params, %{project_path: proj})
    assert msg =~ "outside the project directory"
  end

  @tag :tmp_dir
  test "reads directory returns error", %{project_path: proj} do
    File.mkdir_p!(Path.join(proj, "subdir"))
    params = %{"file_path" => "subdir"}
    assert {:error, msg} = FileRead.run(params, %{project_path: proj})
    assert msg =~ "directory"
  end
end
