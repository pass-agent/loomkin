defmodule Loomkin.Tools.Git do
  @moduledoc "Git operations tool — wraps the git_cli library."

  use Jido.Action,
    name: "git",
    description:
      "Performs git operations in the project repository. " <>
        "Supported operations: status, diff, commit, log, add, reset, stash.",
    schema: [
      operation: [type: :string, required: true, doc: "The git operation to perform"],
      args: [type: :map, doc: "Operation-specific arguments"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  @operations ~w(status diff commit log add reset stash)

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    operation = param!(params, :operation)
    args = param(params, :args, %{})

    repo = Git.new(project_path)
    execute(operation, args, repo)
  end

  defp execute("status", _args, repo) do
    case Git.status(repo, ["--porcelain"]) do
      {:ok, output} ->
        if String.trim(output) == "" do
          {:ok, %{result: "Working tree clean — no changes."}}
        else
          {:ok, %{result: "Git status:\n#{output}"}}
        end

      {:error, %Git.Error{message: msg}} ->
        {:error, "git status failed: #{msg}"}
    end
  end

  defp execute("diff", args, repo) do
    cli_args = build_diff_args(args)

    case Git.diff(repo, cli_args) do
      {:ok, output} ->
        if String.trim(output) == "" do
          {:ok, %{result: "No differences found."}}
        else
          {:ok, %{result: output}}
        end

      {:error, %Git.Error{message: msg}} ->
        {:error, "git diff failed: #{msg}"}
    end
  end

  defp execute("commit", args, repo) do
    message = Map.get(args, "message") || Map.get(args, :message)

    unless message do
      {:error, "Commit message is required. Provide args.message."}
    else
      with :ok <- maybe_stage_files(args, repo) do
        case Git.commit(repo, ["-m", message]) do
          {:ok, output} -> {:ok, %{result: "Commit created:\n#{output}"}}
          {:error, %Git.Error{message: msg}} -> {:error, "git commit failed: #{msg}"}
        end
      end
    end
  end

  defp execute("log", args, repo) do
    count = Map.get(args, "count") || Map.get(args, :count, 10)
    format = Map.get(args, "format") || Map.get(args, :format, "%h %s (%an, %ar)")

    cli_args = ["-#{count}", "--format=#{format}"]

    case Git.log(repo, cli_args) do
      {:ok, output} -> {:ok, %{result: "Recent commits:\n#{output}"}}
      {:error, %Git.Error{message: msg}} -> {:error, "git log failed: #{msg}"}
    end
  end

  defp execute("add", args, repo) do
    files = Map.get(args, "files") || Map.get(args, :files, [])

    if files == [] do
      {:error, "No files specified. Provide args.files as a list of paths."}
    else
      case Git.add(repo, files) do
        {:ok, _} -> {:ok, %{result: "Staged #{length(files)} file(s): #{Enum.join(files, ", ")}"}}
        {:error, %Git.Error{message: msg}} -> {:error, "git add failed: #{msg}"}
      end
    end
  end

  defp execute("reset", args, repo) do
    files = Map.get(args, "files") || Map.get(args, :files, [])

    if files == [] do
      {:error, "No files specified. Provide args.files as a list of paths to unstage."}
    else
      # Always soft reset — never --hard
      case Git.reset(repo, ["HEAD" | files]) do
        {:ok, _} ->
          {:ok, %{result: "Unstaged #{length(files)} file(s): #{Enum.join(files, ", ")}"}}

        {:error, %Git.Error{message: msg}} ->
          {:error, "git reset failed: #{msg}"}
      end
    end
  end

  defp execute("stash", args, repo) do
    action = Map.get(args, "action") || Map.get(args, :action, "push")

    case action do
      "push" ->
        case Git.stash(repo, ["push"]) do
          {:ok, output} -> {:ok, %{result: "Stash pushed:\n#{output}"}}
          {:error, %Git.Error{message: msg}} -> {:error, "git stash push failed: #{msg}"}
        end

      "pop" ->
        case Git.stash(repo, ["pop"]) do
          {:ok, output} -> {:ok, %{result: "Stash popped:\n#{output}"}}
          {:error, %Git.Error{message: msg}} -> {:error, "git stash pop failed: #{msg}"}
        end

      "list" ->
        case Git.stash(repo, ["list"]) do
          {:ok, output} ->
            if String.trim(output) == "" do
              {:ok, %{result: "No stashes found."}}
            else
              {:ok, %{result: "Stash list:\n#{output}"}}
            end

          {:error, %Git.Error{message: msg}} ->
            {:error, "git stash list failed: #{msg}"}
        end

      other ->
        {:error, "Unknown stash action: #{other}. Use push, pop, or list."}
    end
  end

  defp execute(op, _args, _repo) do
    {:error, "Unknown git operation: #{op}. Supported: #{Enum.join(@operations, ", ")}"}
  end

  defp build_diff_args(args) do
    staged = Map.get(args, "staged") || Map.get(args, :staged, false)
    cli_args = if staged, do: ["--cached"], else: []

    file = Map.get(args, "file") || Map.get(args, :file)

    case file do
      nil -> cli_args
      file -> cli_args ++ ["--", file]
    end
  end

  defp maybe_stage_files(args, repo) do
    files = Map.get(args, "files") || Map.get(args, :files)

    case files do
      nil ->
        :ok

      [] ->
        :ok

      files ->
        case Git.add(repo, files) do
          {:ok, _} -> :ok
          {:error, %Git.Error{message: msg}} -> {:error, "Failed to stage files: #{msg}"}
        end
    end
  end
end
