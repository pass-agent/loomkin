defmodule Loomkin.Orchestration.Diff do
  @moduledoc """
  Captures git diff metadata for a single commit in a worktree.

  Used by `WorkUnitPipeline` after a successful commit to publish a
  user-visible diff summary alongside the orchestration phase event.

  The capture is best-effort and MUST NOT raise: a malformed sha or
  a missing worktree returns `{:error, reason}` and the pipeline still
  proceeds (no diff is shown but the commit still succeeded).

  ## Output shape

      %{
        sha: "abc123…",
        stats: %{additions: 12, deletions: 3, files: 2},
        files: [%{path: "lib/x.ex", additions: 10, deletions: 0}, …],
        patch_excerpt: "diff --git a/lib/x.ex …\n…"   # first ~80 lines
      }
  """

  require Logger

  @type file_stat :: %{
          path: String.t(),
          additions: non_neg_integer(),
          deletions: non_neg_integer()
        }

  @type capture :: %{
          sha: String.t(),
          stats: %{
            additions: non_neg_integer(),
            deletions: non_neg_integer(),
            files: non_neg_integer()
          },
          files: [file_stat()],
          patch_excerpt: String.t()
        }

  # Max lines of unified diff retained in `patch_excerpt`. Keeps the
  # broadcast payload small; clients can request a fuller diff out-of-band
  # if they want it.
  @excerpt_line_limit 80

  # Hard ceiling on how long we'll wait for `git show` to return before
  # giving up. The README claims < 200ms for any reasonable commit; this
  # is the bail-out for pathological cases.
  @timeout_ms 1_000

  @spec capture(String.t(), String.t()) :: {:ok, capture()} | {:error, term()}
  def capture(sha, worktree_path) when is_binary(sha) and is_binary(worktree_path) do
    with {:ok, numstat_out} <-
           run_git(["-C", worktree_path, "show", "--numstat", "--format=", sha]),
         {:ok, patch_out} <-
           run_git(["-C", worktree_path, "show", "--no-color", "--max-count=1", sha]) do
      files = parse_numstat(numstat_out)
      stats = aggregate_stats(files)
      excerpt = excerpt_patch(patch_out, @excerpt_line_limit)

      {:ok,
       %{
         sha: sha,
         stats: stats,
         files: files,
         patch_excerpt: excerpt
       }}
    end
  end

  def capture(_sha, _worktree_path), do: {:error, :invalid_args}

  ## Helpers

  defp run_git(args) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        try do
          {out, code} = System.cmd("git", args, stderr_to_stdout: true)
          send(parent, {ref, {:cmd_done, out, code}})
        rescue
          e -> send(parent, {ref, {:cmd_raised, e}})
        catch
          kind, reason -> send(parent, {ref, {:cmd_caught, kind, reason}})
        end
      end)

    receive do
      {^ref, {:cmd_done, out, 0}} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:ok, out}

      {^ref, {:cmd_done, out, code}} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:git_failed, code, String.trim(out)}}

      {^ref, {:cmd_raised, e}} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:git_raised, Exception.message(e)}}

      {^ref, {:cmd_caught, kind, reason}} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:git_caught, kind, inspect(reason)}}
    after
      @timeout_ms ->
        _ = Task.shutdown(task, :brutal_kill)
        Logger.warning("[Diff] git timed out after #{@timeout_ms}ms args=#{inspect(args)}")
        {:error, :timeout}
    end
  end

  # `git show --numstat --format=` emits one line per file:
  #
  #     <additions>\t<deletions>\t<path>
  #
  # Binary files use `-` for the counts; we surface those as `0`/`0` so the
  # totals stay numeric.
  defp parse_numstat(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [adds, dels, path] ->
          [%{path: path, additions: to_int(adds), deletions: to_int(dels)}]

        _ ->
          []
      end
    end)
  end

  defp aggregate_stats(files) do
    Enum.reduce(files, %{additions: 0, deletions: 0, files: 0}, fn f, acc ->
      %{
        additions: acc.additions + f.additions,
        deletions: acc.deletions + f.deletions,
        files: acc.files + 1
      }
    end)
  end

  defp excerpt_patch(out, limit) when is_binary(out) do
    out
    |> String.split("\n")
    |> Enum.take(limit)
    |> Enum.join("\n")
  end

  defp to_int("-"), do: 0
  defp to_int(""), do: 0

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
