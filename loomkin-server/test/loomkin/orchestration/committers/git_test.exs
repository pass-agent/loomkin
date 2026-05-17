defmodule Loomkin.Orchestration.Committers.GitTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Committers.Git

  setup do
    path = Path.join(System.tmp_dir!(), "orch-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Orchestration Test"], cd: path)

    File.write!(Path.join(path, "README.md"), "initial\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)

    on_exit(fn -> File.rm_rf(path) end)
    %{path: path}
  end

  test "commits staged changes and returns a sha", %{path: path} do
    File.write!(Path.join(path, "x.txt"), "hello\n")

    assert {:ok, sha} =
             Git.commit(%{
               worktree_path: path,
               work_unit_id: "wu-1",
               verdict_summary: "stub pass"
             })

    assert is_binary(sha)
    assert byte_size(sha) >= 7

    {log, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: path)
    assert String.contains?(log, "wu-1")
  end

  test "returns nothing_to_commit when there are no changes", %{path: path} do
    assert {:error, {:nothing_to_commit, _}} =
             Git.commit(%{worktree_path: path, work_unit_id: "wu-2"})
  end

  test "respects files_touched when provided", %{path: path} do
    File.write!(Path.join(path, "a.txt"), "a\n")
    File.write!(Path.join(path, "b.txt"), "b\n")

    assert {:ok, _sha} =
             Git.commit(%{
               worktree_path: path,
               work_unit_id: "wu-3",
               files_touched: ["a.txt"]
             })

    {tracked, 0} = System.cmd("git", ["ls-files"], cd: path)
    assert String.contains?(tracked, "a.txt")
    refute String.contains?(tracked, "b.txt")
  end
end
