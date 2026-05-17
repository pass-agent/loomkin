defmodule Loomkin.Orchestration.Validators.ElixirFormat do
  @moduledoc """
  Runs `mix format --check-formatted` against the worktree.

  Expected payload key: `:worktree_path` (binary). Returns `:ok` when the
  command exits 0; otherwise `{:error, [diagnostic, ...]}`.
  """
  @behaviour Loomkin.Orchestration.Validators.Validator

  @impl true
  def name, do: :elixir_format

  @impl true
  def validate(payload, opts \\ []) do
    case payload[:worktree_path] || payload["worktree_path"] do
      nil ->
        {:error, ["validator:elixir_format:1: missing :worktree_path in payload"]}

      path when is_binary(path) ->
        timeout = Keyword.get(opts, :timeout, 60_000)

        case run(path, timeout) do
          {_out, 0} ->
            :ok

          {out, _code} ->
            {:error, parse_errors(out, path)}
        end
    end
  end

  defp run(path, timeout) do
    Task.async(fn ->
      System.cmd("mix", ["format", "--check-formatted"],
        cd: path,
        stderr_to_stdout: true,
        env: env_for_subprocess()
      )
    end)
    |> Task.await(timeout)
  end

  defp env_for_subprocess do
    [
      {"MIX_ENV", System.get_env("MIX_ENV", "dev")}
    ]
  end

  defp parse_errors(out, _path) do
    # mix format prints "** (Mix) mix format failed due to --check-formatted." with
    # a list of files. We surface every file:line shape we can find.
    lines = String.split(out, "\n", trim: true)

    file_lines =
      Enum.flat_map(lines, fn line ->
        case Regex.run(~r/\s+(\S+\.exs?)\b/, line) do
          [_, file] -> ["#{file}:1: not formatted"]
          _ -> []
        end
      end)

    if file_lines == [] do
      ["validator:elixir_format:0: mix format check failed (#{String.slice(out, 0, 200)})"]
    else
      file_lines
    end
  end
end
