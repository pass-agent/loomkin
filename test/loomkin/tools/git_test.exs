defmodule Loomkin.Tools.GitTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.Git, as: GitTool

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    # Initialize a git repo in the tmp directory
    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    # Create an initial commit so we have a HEAD
    File.write!(Path.join(tmp_dir, "README.md"), "# Test\n")
    System.cmd("git", ["add", "."], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_dir)

    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert GitTool.name() == "git"
    assert is_binary(GitTool.description())
  end

  @tag :tmp_dir
  test "status shows clean working tree", %{project_path: proj} do
    params = %{"operation" => "status"}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "clean"
  end

  @tag :tmp_dir
  test "status shows modified files", %{project_path: proj} do
    File.write!(Path.join(proj, "new.txt"), "new file\n")
    params = %{"operation" => "status"}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "new.txt"
  end

  @tag :tmp_dir
  test "add stages files", %{project_path: proj} do
    File.write!(Path.join(proj, "staged.txt"), "content\n")
    params = %{"operation" => "add", "args" => %{"files" => ["staged.txt"]}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Staged 1 file"
  end

  @tag :tmp_dir
  test "add requires files", %{project_path: proj} do
    params = %{"operation" => "add", "args" => %{"files" => []}}
    assert {:error, msg} = GitTool.run(params, %{project_path: proj})
    assert msg =~ "No files specified"
  end

  @tag :tmp_dir
  test "commit creates a commit", %{project_path: proj} do
    File.write!(Path.join(proj, "committed.txt"), "content\n")
    System.cmd("git", ["add", "committed.txt"], cd: proj)

    params = %{"operation" => "commit", "args" => %{"message" => "Add committed.txt"}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Commit created"
  end

  @tag :tmp_dir
  test "commit with files stages then commits", %{project_path: proj} do
    File.write!(Path.join(proj, "auto.txt"), "auto\n")

    params = %{
      "operation" => "commit",
      "args" => %{"message" => "Auto-stage commit", "files" => ["auto.txt"]}
    }

    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Commit created"
  end

  @tag :tmp_dir
  test "commit requires message", %{project_path: proj} do
    params = %{"operation" => "commit", "args" => %{}}
    assert {:error, msg} = GitTool.run(params, %{project_path: proj})
    assert msg =~ "message is required"
  end

  @tag :tmp_dir
  test "diff shows changes", %{project_path: proj} do
    File.write!(Path.join(proj, "README.md"), "# Modified\n")
    params = %{"operation" => "diff"}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Modified"
  end

  @tag :tmp_dir
  test "diff with staged flag", %{project_path: proj} do
    File.write!(Path.join(proj, "README.md"), "# Staged change\n")
    System.cmd("git", ["add", "README.md"], cd: proj)

    params = %{"operation" => "diff", "args" => %{"staged" => true}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Staged change"
  end

  @tag :tmp_dir
  test "diff with no changes", %{project_path: proj} do
    params = %{"operation" => "diff"}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "No differences"
  end

  @tag :tmp_dir
  test "log shows commits", %{project_path: proj} do
    params = %{"operation" => "log", "args" => %{"count" => 5}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Initial commit"
  end

  @tag :tmp_dir
  test "reset unstages files", %{project_path: proj} do
    File.write!(Path.join(proj, "unstage.txt"), "content\n")
    System.cmd("git", ["add", "unstage.txt"], cd: proj)

    params = %{"operation" => "reset", "args" => %{"files" => ["unstage.txt"]}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Unstaged"
  end

  @tag :tmp_dir
  test "reset requires files", %{project_path: proj} do
    params = %{"operation" => "reset", "args" => %{}}
    assert {:error, msg} = GitTool.run(params, %{project_path: proj})
    assert msg =~ "No files specified"
  end

  @tag :tmp_dir
  test "stash push and pop", %{project_path: proj} do
    File.write!(Path.join(proj, "README.md"), "# Stashed\n")

    params = %{"operation" => "stash", "args" => %{"action" => "push"}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Stash pushed"

    params = %{"operation" => "stash", "args" => %{"action" => "pop"}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "Stash popped"
  end

  @tag :tmp_dir
  test "stash list when empty", %{project_path: proj} do
    params = %{"operation" => "stash", "args" => %{"action" => "list"}}
    assert {:ok, %{result: result}} = GitTool.run(params, %{project_path: proj})
    assert result =~ "No stashes"
  end

  @tag :tmp_dir
  test "unknown operation returns error", %{project_path: proj} do
    params = %{"operation" => "rebase"}
    assert {:error, msg} = GitTool.run(params, %{project_path: proj})
    assert msg =~ "Unknown git operation"
  end
end
