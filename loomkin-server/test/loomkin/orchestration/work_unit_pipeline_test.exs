defmodule Loomkin.Orchestration.WorkUnitPipelineTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Schema.ReviewVerdict
  alias Loomkin.Orchestration.WorkUnitPipeline

  defp wait_for(server, predicate, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(server, predicate, deadline)
  end

  defp do_wait_for(server, predicate, deadline) do
    {state, _data} = WorkUnitPipeline.status(server)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for predicate; last state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        do_wait_for(server, predicate, deadline)
    end
  end

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

  defp fail_verdict do
    %ReviewVerdict{
      verdict: :fail,
      reviewer: "stub",
      evidence: ["lib/x.ex:2"],
      blocking: ["nope"],
      warnings: [],
      rationale: "no"
    }
  end

  test "happy path: implement → validate → adversarial_review → commit → done" do
    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _art -> :ok end,
      reviewer: fn _art -> {:pass, [ok_verdict()]} end,
      committer: fn _art -> {:ok, "sha-1"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-1", title: "t"},
        callbacks: callbacks,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 == :done))
    assert state == :done

    assert_receive {:work_unit_pipeline, ^pid, :completed}, 1_000
  end

  test "validator failure retries implement up to the cap then fails" do
    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _art -> {:error, ["bad"]} end,
      reviewer: fn _art -> {:pass, [ok_verdict()]} end,
      committer: fn _art -> {:ok, "sha-1"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-2", title: "t"},
        callbacks: callbacks,
        max_iterations: 2,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 == :failed))
    assert state == :failed
    assert_receive {:work_unit_pipeline, ^pid, :failed}, 1_000
  end

  test "adversarial review fail triggers retry then succeeds" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _ -> :ok end,
      reviewer: fn _ ->
        n = Agent.get_and_update(agent, &{&1, &1 + 1})
        if n == 0, do: {:fail, [fail_verdict()]}, else: {:pass, [ok_verdict()]}
      end,
      committer: fn _ -> {:ok, "sha-2"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-3", title: "t"},
        callbacks: callbacks,
        max_iterations: 3,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 in [:done, :failed]), 2_000)
    assert state == :done
    assert_receive {:work_unit_pipeline, ^pid, :completed}, 1_000
  end

  test "successful commit broadcasts a :diff event on orchestration.work_unit" do
    path =
      Path.join(System.tmp_dir!(), "wu-pipeline-diff-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Pipeline Diff Test"], cd: path)
    File.write!(Path.join(path, "README.md"), "initial\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)

    File.write!(Path.join(path, "x.txt"), "x\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "x"], cd: path)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    sha = String.trim(sha)

    on_exit(fn -> File.rm_rf(path) end)

    :ok = Phoenix.PubSub.subscribe(Loomkin.PubSub, "orchestration.work_unit")

    artifact = %{worktree_path: path, files_touched: ["x.txt"]}

    callbacks = %{
      implementer: fn _wu -> {:ok, artifact} end,
      validator: fn _ -> :ok end,
      reviewer: fn _ -> {:pass, [ok_verdict()]} end,
      committer: fn _ -> {:ok, sha} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-diff", title: "diff"},
        callbacks: callbacks,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 == :done), 2_000)
    assert state == :done

    assert_receive {"orchestration.work_unit",
                    %{
                      work_unit_id: "wu-diff",
                      event: :diff,
                      sha: ^sha,
                      stats: %{files: files_count}
                    } = payload},
                   1_500

    assert files_count >= 1
    assert is_list(payload.files)
    assert String.contains?(payload.patch_excerpt, "diff --git")
  end
end
