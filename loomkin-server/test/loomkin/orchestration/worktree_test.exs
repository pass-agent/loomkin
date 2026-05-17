defmodule Loomkin.Orchestration.WorktreeTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Worktree

  test "dry_run mode does not touch git" do
    {:ok, pid} =
      Worktree.start_link(
        repo_path: "/nope/should/not/exist",
        path: "/tmp/orch-test-doesnt-exist",
        branch: "orch/test-#{System.unique_integer([:positive])}",
        dry_run: true
      )

    info = Worktree.info(pid)
    assert info.created? == true
    assert info.branch =~ "orch/test-"

    Worktree.with_path(pid, fn p ->
      assert is_binary(p)
    end)
  end
end
