defmodule Loomkin.Collaboration.WorktreeTest do
  use ExUnit.Case, async: true

  alias Loomkin.Collaboration.Worktree

  @workspace_id "abcdef12-3456-7890-abcd-ef1234567890"
  @user_id 42

  setup do
    # Create a temporary git repo to test worktree operations
    tmp_dir =
      Path.join(System.tmp_dir!(), "loomkin_wt_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    {_, 0} = System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["commit", "--allow-empty", "-m", "initial"],
        cd: tmp_dir,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@test.com"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@test.com"}
        ]
      )

    on_exit(fn ->
      # Clean up worktrees before removing the main repo
      wt_path = Worktree.worktree_path(@workspace_id, @user_id, tmp_dir)

      if File.exists?(wt_path) do
        System.cmd("git", ["worktree", "remove", wt_path, "--force"],
          cd: tmp_dir,
          stderr_to_stdout: true
        )
      end

      File.rm_rf!(tmp_dir)
      File.rm_rf!(wt_path)
    end)

    %{project_path: tmp_dir}
  end

  describe "worktree_path/3" do
    test "produces deterministic path for workspace + user pair", %{project_path: path} do
      result1 = Worktree.worktree_path(@workspace_id, @user_id, path)
      result2 = Worktree.worktree_path(@workspace_id, @user_id, path)
      assert result1 == result2
    end

    test "different users get different paths", %{project_path: path} do
      path1 = Worktree.worktree_path(@workspace_id, 1, path)
      path2 = Worktree.worktree_path(@workspace_id, 2, path)
      refute path1 == path2
    end

    test "path is adjacent to project directory", %{project_path: path} do
      wt_path = Worktree.worktree_path(@workspace_id, @user_id, path)
      assert Path.dirname(wt_path) == Path.dirname(path)
    end

    test "path contains workspace and user identifiers", %{project_path: path} do
      wt_path = Worktree.worktree_path(@workspace_id, @user_id, path)
      assert String.contains?(wt_path, "collab")
      assert String.contains?(wt_path, "42")
      assert String.contains?(wt_path, "abcdef1234567890abcdef1234567890")
    end
  end

  describe "branch_name/2" do
    test "produces deterministic branch name" do
      name = Worktree.branch_name(@workspace_id, @user_id)
      assert name == "collab/abcdef1234567890abcdef1234567890/42"
    end

    test "different users get different branches" do
      name1 = Worktree.branch_name(@workspace_id, 1)
      name2 = Worktree.branch_name(@workspace_id, 2)
      refute name1 == name2
    end
  end

  describe "create_worktree/3" do
    test "creates a valid git worktree", %{project_path: path} do
      assert {:ok, wt_path} = Worktree.create_worktree(@workspace_id, @user_id, path)
      assert File.exists?(wt_path)
      assert File.dir?(wt_path)

      # Verify it's actually a git worktree
      {output, 0} = System.cmd("git", ["worktree", "list"], cd: path, stderr_to_stdout: true)
      assert String.contains?(output, wt_path)
    end

    test "creating same worktree twice is idempotent", %{project_path: path} do
      assert {:ok, wt_path1} = Worktree.create_worktree(@workspace_id, @user_id, path)
      assert {:ok, wt_path2} = Worktree.create_worktree(@workspace_id, @user_id, path)
      assert wt_path1 == wt_path2
    end

    test "worktree is on the correct branch", %{project_path: path} do
      {:ok, wt_path} = Worktree.create_worktree(@workspace_id, @user_id, path)
      expected_branch = Worktree.branch_name(@workspace_id, @user_id)

      {output, 0} =
        System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
          cd: wt_path,
          stderr_to_stdout: true
        )

      assert String.trim(output) == expected_branch
    end

    test "returns error for non-git project path" do
      non_git_dir =
        Path.join(System.tmp_dir!(), "loomkin_wt_no_git_#{System.unique_integer([:positive])}")

      File.mkdir_p!(non_git_dir)

      on_exit(fn -> File.rm_rf!(non_git_dir) end)

      assert {:error, {:worktree_creation_failed, _output}} =
               Worktree.create_worktree(@workspace_id, @user_id, non_git_dir)
    end
  end

  describe "remove_worktree/3" do
    test "removes an existing worktree", %{project_path: path} do
      {:ok, wt_path} = Worktree.create_worktree(@workspace_id, @user_id, path)
      assert File.exists?(wt_path)

      assert :ok = Worktree.remove_worktree(@workspace_id, @user_id, path)
      refute File.exists?(wt_path)
    end

    test "removing non-existent worktree is a no-op", %{project_path: path} do
      assert :ok = Worktree.remove_worktree(@workspace_id, @user_id, path)
    end

    test "also deletes the branch", %{project_path: path} do
      {:ok, _wt_path} = Worktree.create_worktree(@workspace_id, @user_id, path)
      branch = Worktree.branch_name(@workspace_id, @user_id)

      # Branch should exist before removal
      {branches_before, 0} =
        System.cmd("git", ["branch", "--list", branch], cd: path, stderr_to_stdout: true)

      assert String.contains?(branches_before, branch)

      :ok = Worktree.remove_worktree(@workspace_id, @user_id, path)

      # Branch should be gone after removal
      {branches_after, 0} =
        System.cmd("git", ["branch", "--list", branch], cd: path, stderr_to_stdout: true)

      refute String.contains?(branches_after, branch)
    end
  end
end
