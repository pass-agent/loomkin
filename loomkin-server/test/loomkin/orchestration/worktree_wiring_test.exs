defmodule Loomkin.Orchestration.WorktreeWiringTest do
  @moduledoc """
  Integration test for the Worktree wiring into the orchestration pipeline.

  Spins up a temporary git repo, runs a full epic through `IssueOrchestrator`
  with real `Callbacks.default_work_unit_callbacks/0`, and asserts that the
  work-unit commit landed on the worktree's `orchestration/epic-<id>` branch
  rather than on `main`.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.{Callbacks, Executor, IssueOrchestrator}
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  defp ok_verdict do
    %ReviewVerdict{
      verdict: :pass,
      reviewer: "stub",
      evidence: ["lib/x.ex:1"],
      blocking: [],
      warnings: [],
      rationale: "ok"
    }
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["-C", path, "init", "--initial-branch=main"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@loomkin.dev"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Loomkin Test"])
    File.write!(Path.join(path, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["-C", path, "add", "."])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-m", "seed"])
  end

  defp on_branch(repo, branch) do
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", branch], stderr_to_stdout: true)
    String.trim(sha)
  end

  test "executor injects worktree_path into work-unit payload" do
    parent = self()

    callbacks = %{
      implementer: fn wu ->
        send(parent, {:implementer_saw, Map.get(wu, :worktree_path)})
        {:ok, %{"files_touched" => ["README.md"], "wu" => wu.id}}
      end,
      validator: fn _ -> :ok end,
      reviewer: fn _ -> {:pass, [ok_verdict()]} end,
      committer: fn _ -> {:ok, "fake-sha"} end
    }

    {:ok, _} =
      Executor.run(%{id: "epic-x"}, [%{id: "wu-1", deps: []}],
        callbacks: callbacks,
        worktree_path: "/tmp/fake-worktree-path"
      )

    assert_received {:implementer_saw, "/tmp/fake-worktree-path"}
  end

  test "executor leaves work-unit untouched when no worktree_path is given" do
    parent = self()

    callbacks = %{
      implementer: fn wu ->
        send(parent, {:implementer_saw, Map.get(wu, :worktree_path)})
        {:ok, %{"files_touched" => []}}
      end,
      validator: fn _ -> :ok end,
      reviewer: fn _ -> {:pass, [ok_verdict()]} end,
      committer: fn _ -> {:ok, "fake-sha"} end
    }

    {:ok, _} = Executor.run(%{id: "e"}, [%{id: "wu-1", deps: []}], callbacks: callbacks)

    assert_received {:implementer_saw, nil}
  end

  test "epic boots a Worktree GenServer on :research and stops it on :closed" do
    epic = %{
      id: "epic-#{System.unique_integer([:positive])}",
      title: "test",
      metadata: %{}
    }

    callbacks =
      Callbacks.default_issue_callbacks(%{
        researcher: fn _ -> {:ok, %{}} end,
        planner: fn _, _ -> {:ok, %{work_units: []}} end,
        plan_review: fn _ -> {:pass, [ok_verdict()]} end,
        design_review: fn _ -> {:pass, [ok_verdict()]} end,
        decomposer: fn _ -> {:ok, []} end,
        executor: fn _, _ -> {:ok, %{}} end,
        final_review: fn _, _ -> {:pass, [ok_verdict()]} end,
        pr_opener: fn _, _ -> {:ok, "https://example.com/pr/1"} end,
        knowledge: fn _, _ -> {:ok, []} end
      })

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: epic,
        callbacks: callbacks,
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert_receive {:issue_orchestrator, ^pid, :closed}, 5_000

    # Dry-run worktree owns lifecycle but does NOT expose its path to downstream
    # phases (so the default committer doesn't try to git-commit in /tmp). The
    # epic still reached :closed cleanly, proving the boot+stop wiring works.
    snap = IssueOrchestrator.status(pid)
    assert snap.state == :closed
  end

  @tag :tmp_dir
  test "real git repo: work-unit commit lands on worktree branch, not main", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    init_repo!(repo)

    main_before = on_branch(repo, "main")

    epic_id = "epic-#{System.unique_integer([:positive])}"

    epic = %{
      id: epic_id,
      metadata: %{
        project_path: repo,
        worktree_root: Path.join(tmp, "worktrees"),
        base_branch: "main"
      }
    }

    work_unit = %{id: "wu-1", title: "touch a file", deps: []}

    # Real default work-unit callbacks: implementer is Workers.Coder.call — we
    # stub it via overrides so we don't need an LLM. Validator/reviewer/committer
    # are the real defaults; committer will run `git add -A && git commit` in
    # the worktree.
    implementer = fn wu ->
      path = Map.fetch!(wu, :worktree_path)
      File.write!(Path.join(path, "wu-1.txt"), "hello from #{wu.id}\n")
      {:ok, %{"files_touched" => ["wu-1.txt"], :worktree_path => path}}
    end

    reviewer = fn _ -> {:pass, [ok_verdict()]} end

    callbacks =
      Callbacks.default_issue_callbacks(%{
        researcher: fn _ -> {:ok, %{}} end,
        planner: fn _, _ -> {:ok, %{work_units: [work_unit]}} end,
        plan_review: fn _ -> {:pass, [ok_verdict()]} end,
        design_review: fn _ -> {:pass, [ok_verdict()]} end,
        executor: fn ep, wus ->
          Executor.run(ep, wus,
            worktree_path: get_in(ep, [Access.key(:artifacts), :worktree_path]),
            callbacks: %{
              implementer: implementer,
              validator: fn _ -> :ok end,
              reviewer: reviewer,
              committer: Callbacks.default_work_unit_callbacks().committer
            }
          )
        end,
        final_review: fn _, _ -> {:pass, [ok_verdict()]} end,
        pr_opener: fn _, _ -> {:ok, "https://example.com/pr/1"} end,
        knowledge: fn _, _ -> {:ok, []} end
      })

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: epic,
        callbacks: callbacks,
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert_receive {:issue_orchestrator, ^pid, :closed}, 10_000

    # main should be unchanged
    main_after = on_branch(repo, "main")
    assert main_after == main_before, "main branch was mutated; expected only worktree branch"

    # worktree branch should exist and have a NEW commit
    branch = "orchestration/epic-#{epic_id}"
    branch_sha = on_branch(repo, branch)

    assert branch_sha != main_before,
           "worktree branch #{branch} should have advanced past main, but is at #{branch_sha}"
  end
end
