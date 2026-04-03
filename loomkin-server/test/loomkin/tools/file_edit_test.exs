defmodule Loomkin.Tools.FileEditTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FileEdit

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "editable.txt")
    File.write!(file, "Hello, world!\nHello, Elixir!\nGoodbye, world!\n")
    %{project_path: tmp_dir, edit_file: file}
  end

  test "action metadata is correct" do
    assert FileEdit.name() == "file_edit"
    assert is_binary(FileEdit.description())
  end

  @tag :tmp_dir
  test "replaces a unique string", %{project_path: proj, edit_file: file} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello, Elixir!",
      "new_string" => "Hello, Loomkin!"
    }

    assert {:ok, %{result: msg}} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "1 occurrence"
    assert File.read!(file) =~ "Hello, Loomkin!"
    refute File.read!(file) =~ "Hello, Elixir!"
  end

  @tag :tmp_dir
  test "fails when old_string not found", %{project_path: proj} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "MISSING",
      "new_string" => "replacement"
    }

    assert {:error, msg} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "fails when old_string is ambiguous (multiple matches)", %{project_path: proj} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello,",
      "new_string" => "Hi,"
    }

    assert {:error, msg} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "2 times"
  end

  @tag :tmp_dir
  test "replace_all replaces every occurrence", %{project_path: proj, edit_file: file} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello,",
      "new_string" => "Hi,",
      "replace_all" => true
    }

    assert {:ok, %{result: msg}} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "2 occurrence"
    content = File.read!(file)
    assert content =~ "Hi, world!"
    assert content =~ "Hi, Elixir!"
  end

  @tag :tmp_dir
  test "returns error for missing file", %{project_path: proj} do
    params = %{
      "file_path" => "nope.txt",
      "old_string" => "a",
      "new_string" => "b"
    }

    assert {:error, msg} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "File not found"
  end

  @tag :tmp_dir
  test "rejects path traversal", %{project_path: proj} do
    params = %{
      "file_path" => "../../etc/passwd",
      "old_string" => "root",
      "new_string" => "hacked"
    }

    assert {:error, msg} = FileEdit.run(params, %{project_path: proj})
    assert msg =~ "outside the project directory"
  end

  @tag :tmp_dir
  test "warns when editing a file not in read_files set", %{project_path: proj} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello, Elixir!",
      "new_string" => "Hello, Loomkin!"
    }

    context = %{project_path: proj, read_files: MapSet.new()}

    assert {:ok, %{result: msg}} = FileEdit.run(params, context)
    assert msg =~ "Warning: You are editing a file you haven't read yet"
    assert msg =~ "1 occurrence"
  end

  @tag :tmp_dir
  test "no warning when file is in read_files set", %{project_path: proj} do
    full_path = Path.join(proj, "editable.txt")

    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello, Elixir!",
      "new_string" => "Hello, Loomkin!"
    }

    context = %{project_path: proj, read_files: MapSet.new([full_path])}

    assert {:ok, %{result: msg}} = FileEdit.run(params, context)
    refute msg =~ "Warning"
    assert msg =~ "1 occurrence"
  end

  @tag :tmp_dir
  test "no warning when read_files is not in context", %{project_path: proj} do
    params = %{
      "file_path" => "editable.txt",
      "old_string" => "Hello, Elixir!",
      "new_string" => "Hello, Loomkin!"
    }

    context = %{project_path: proj}

    assert {:ok, %{result: msg}} = FileEdit.run(params, context)
    refute msg =~ "Warning"
    assert msg =~ "1 occurrence"
  end
end
