defmodule Loomkin.Tools.ContentSearch do
  @moduledoc "Searches file contents using a regex pattern."

  use Jido.Action,
    name: "content_search",
    description:
      "Searches file contents for lines matching a regex pattern. " <>
        "Returns matches as file:line_number:content. " <>
        "Results are capped at 100 matches.",
    schema: [
      pattern: [type: :string, required: true, doc: "Regex pattern to search for"],
      path: [type: :string, doc: "Directory to search in (relative to project root, defaults to root)"],
      glob: [type: :string, doc: "File filter glob pattern (e.g. \"*.ex\", \"*.{ex,exs}\")"]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2, param: 2, param: 3]

  @max_results 100
  @ignore_dirs ~w(.git _build deps node_modules .elixir_ls .lexical)

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    pattern_str = param!(params, :pattern)
    sub_path = param(params, :path)
    glob = param(params, :glob, "**/*")

    search_dir =
      if sub_path do
        safe_path!(sub_path, project_path)
      else
        project_path
      end

    case Regex.compile(pattern_str) do
      {:ok, regex} ->
        glob_pattern =
          if String.contains?(glob, "/") or String.starts_with?(glob, "**") do
            glob
          else
            "**/" <> glob
          end

        full_glob = Path.join(search_dir, glob_pattern)

        matches =
          Path.wildcard(full_glob, match_dot: false)
          |> Enum.reject(&ignored?/1)
          |> Enum.reject(&File.dir?/1)
          |> Enum.flat_map(&search_file(&1, regex, project_path))
          |> Enum.take(@max_results)

        case matches do
          [] ->
            {:ok, %{result: "No matches found for pattern: #{pattern_str}"}}

          results ->
            truncated =
              if length(results) >= @max_results, do: " (truncated at #{@max_results})", else: ""

            header = "Found #{length(results)} match(es)#{truncated}:\n"
            {:ok, %{result: header <> Enum.join(results, "\n")}}
        end

      {:error, {reason, _}} ->
        {:error, "Invalid regex pattern: #{reason}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp search_file(file_path, regex, project_path) do
    rel_path = Path.relative_to(file_path, project_path)

    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, num} -> "#{rel_path}:#{num}:#{String.trim_trailing(line)}" end)

      {:error, _} ->
        []
    end
  end

  defp ignored?(path) do
    parts = Path.split(path)
    Enum.any?(@ignore_dirs, fn dir -> dir in parts end)
  end
end
