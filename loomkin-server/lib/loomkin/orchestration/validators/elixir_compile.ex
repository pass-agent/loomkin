defmodule Loomkin.Orchestration.Validators.ElixirCompile do
  @moduledoc """
  Runs `mix compile --warnings-as-errors` against the worktree.

  Payload key: `:worktree_path`. Returns `:ok` or `{:error, [diag]}` where
  each diagnostic is a `file:line: message` string parsed from compiler output.
  """
  @behaviour Loomkin.Orchestration.Validators.Validator

  @impl true
  def name, do: :elixir_compile

  @impl true
  def validate(payload, opts \\ []) do
    case payload[:worktree_path] || payload["worktree_path"] do
      nil ->
        {:error, ["validator:elixir_compile:1: missing :worktree_path"]}

      path when is_binary(path) ->
        timeout = Keyword.get(opts, :timeout, 300_000)

        case run(path, timeout) do
          {_out, 0} -> :ok
          {out, _code} -> {:error, parse_errors(out)}
        end
    end
  end

  defp run(path, timeout) do
    Task.async(fn ->
      System.cmd("mix", ["compile", "--warnings-as-errors", "--no-deps-check"],
        cd: path,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", System.get_env("MIX_ENV", "dev")}]
      )
    end)
    |> Task.await(timeout)
  end

  # Lines like:
  #   ** (CompileError) lib/x.ex:42:5: undefined function ...
  #   lib/x.ex:10: warning: foo is unused
  defp parse_errors(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/(\S+\.exs?):(\d+)(?::\d+)?[:\s]+(.+)/, line) do
        [_, file, line_no, message] -> ["#{file}:#{line_no}: #{String.trim(message)}"]
        _ -> []
      end
    end)
    |> case do
      [] -> ["validator:elixir_compile:0: compile failed (no parseable diagnostic)"]
      list -> list
    end
  end
end
