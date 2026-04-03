defmodule Loomkin.Tools.FileSearch do
  @moduledoc "Searches for files matching a glob pattern."

  use Jido.Action,
    name: "file_search",
    description:
      "Searches for files matching a glob pattern (e.g. \"**/*.ex\"). " <>
        "Returns matching file paths sorted by modification time (most recent first). " <>
        "Common directories like .git, _build, deps, and node_modules are excluded.",
    schema: [
      pattern: [
        type: :string,
        required: true,
        doc: "Glob pattern to match (e.g. \"**/*.ex\", \"lib/**/*.ex\")"
      ],
      path: [
        type: :string,
        doc: "Directory to search in (relative to project root, defaults to root)"
      ]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2, param: 2]

  @ignore_dirs ~w(.git _build deps node_modules .elixir_ls .lexical)

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    pattern = param!(params, :pattern)
    sub_path = param(params, :path)

    search_dir =
      if sub_path do
        safe_path!(sub_path, project_path)
      else
        project_path
      end

    full_pattern = Path.join(search_dir, pattern)

    matches =
      Path.wildcard(full_pattern, match_dot: true)
      |> Enum.reject(&ignored?/1)
      |> sort_by_mtime()
      |> Enum.map(&Path.relative_to(&1, project_path))

    case matches do
      [] ->
        {:ok, %{result: "No files matched pattern: #{pattern}"}}

      files ->
        header = "Found #{length(files)} file(s):\n"
        {:ok, %{result: header <> Enum.join(files, "\n")}}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp ignored?(path) do
    parts = Path.split(path)
    Enum.any?(@ignore_dirs, fn dir -> dir in parts end)
  end

  defp sort_by_mtime(paths) do
    Enum.sort_by(
      paths,
      fn path ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} -> mtime
          _ -> 0
        end
      end,
      :desc
    )
  end
end
