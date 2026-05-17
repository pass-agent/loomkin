defmodule Loomkin.Orchestration.Validators.ElixirTest do
  @moduledoc """
  Runs `mix test` against the worktree.

  Payload keys:
    * `:worktree_path` (required)
    * `:test_paths` (optional list of paths to limit which tests run; default runs all)

  Returns `:ok` or `{:error, [diag]}` where each diag is a `file:line: failure`
  string parsed from ExUnit output.
  """
  @behaviour Loomkin.Orchestration.Validators.Validator

  @impl true
  def name, do: :elixir_test

  @impl true
  def validate(payload, opts \\ []) do
    case payload[:worktree_path] || payload["worktree_path"] do
      nil ->
        {:error, ["validator:elixir_test:1: missing :worktree_path"]}

      path when is_binary(path) ->
        timeout = Keyword.get(opts, :timeout, 600_000)
        test_paths = List.wrap(payload[:test_paths] || payload["test_paths"] || [])

        case run(path, test_paths, timeout) do
          {_out, 0} -> :ok
          {out, _code} -> {:error, parse_failures(out)}
        end
    end
  end

  defp run(path, test_paths, timeout) do
    args = ["test", "--no-deps-check"] ++ test_paths

    Task.async(fn ->
      System.cmd("mix", args,
        cd: path,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end)
    |> Task.await(timeout)
  end

  # ExUnit failure lines:
  #   1) test failing thing (Some.Module.Test)
  #      test/path/to_test.exs:42
  defp parse_failures(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\s+(test\/\S+_test\.exs?):(\d+)/, line) do
        [_, file, line_no] -> ["#{file}:#{line_no}: test failure"]
        _ -> []
      end
    end)
    |> case do
      [] -> ["validator:elixir_test:0: tests failed (no parseable diagnostic)"]
      list -> Enum.uniq(list)
    end
  end
end
