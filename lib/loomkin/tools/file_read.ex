defmodule Loomkin.Tools.FileRead do
  @moduledoc "Reads a file and returns its contents with line numbers."

  use Jido.Action,
    name: "file_read",
    description:
      "Reads a file from the project. Returns contents formatted with line numbers. " <>
        "Use offset and limit to read specific sections of large files.",
    schema: [
      file_path: [type: :string, required: true, doc: "Path to the file (relative to project root)"],
      offset: [type: :integer, doc: "Line number to start reading from (1-based)"],
      limit: [type: :integer, doc: "Maximum number of lines to return"]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2, param: 2]

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    file_path = param!(params, :file_path)
    offset = param(params, :offset)
    limit = param(params, :limit)

    full_path = safe_path!(file_path, project_path)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: false)
        # Remove trailing empty element from trailing newline
        lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

        total = length(lines)

        start_idx = if offset && offset > 0, do: offset - 1, else: 0
        selected = Enum.drop(lines, start_idx)
        selected = if limit && limit > 0, do: Enum.take(selected, limit), else: selected

        formatted =
          selected
          |> Enum.with_index(start_idx + 1)
          |> Enum.map(fn {line, num} ->
            num_str = num |> Integer.to_string() |> String.pad_leading(6)
            "#{num_str}\t#{line}"
          end)
          |> Enum.join("\n")

        shown = length(selected)
        header = "#{full_path} (#{total} lines total, showing #{shown})\n"
        {:ok, %{result: header <> formatted}}

      {:error, :enoent} ->
        {:error, "File not found: #{full_path}"}

      {:error, :eisdir} ->
        {:error, "Path is a directory, not a file: #{full_path}"}

      {:error, reason} ->
        {:error, "Failed to read #{full_path}: #{reason}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end
end
