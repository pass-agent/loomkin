defmodule Loomkin.Tools.DirectoryList do
  @moduledoc "Lists directory contents with file metadata."

  use Jido.Action,
    name: "directory_list",
    description:
      "Lists the contents of a directory, showing file type, size, and modification time.",
    schema: [
      path: [type: :string, required: true, doc: "Directory path (relative to project root)"]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2]

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    dir_path = param!(params, :path)

    full_path = safe_path!(dir_path, project_path)

    case File.ls(full_path) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.map(fn entry ->
            entry_path = Path.join(full_path, entry)
            format_entry(entry, entry_path)
          end)

        rel = Path.relative_to(full_path, project_path)
        header = "#{rel}/ (#{length(lines)} entries)\n"
        {:ok, %{result: header <> Enum.join(lines, "\n")}}

      {:error, :enoent} ->
        {:error, "Directory not found: #{full_path}"}

      {:error, :enotdir} ->
        {:error, "Not a directory: #{full_path}"}

      {:error, reason} ->
        {:error, "Failed to list #{full_path}: #{reason}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp format_entry(name, path) do
    case File.lstat(path) do
      {:ok, %{type: type, size: size, mtime: mtime}} ->
        type_label = type_label(type)
        size_str = format_size(size)
        time_str = format_time(mtime)
        suffix = if type == :directory, do: "/", else: ""
        "  #{type_label}  #{String.pad_leading(size_str, 8)}  #{time_str}  #{name}#{suffix}"

      {:error, _} ->
        "  ???     ?        ?           #{name}"
    end
  end

  defp type_label(:regular), do: "file"
  defp type_label(:directory), do: " dir"
  defp type_label(:symlink), do: "link"
  defp type_label(_), do: " ???"

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1024)}KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"

  defp format_time({{y, m, d}, {h, min, _s}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [y, m, d, h, min])
    |> IO.iodata_to_binary()
  end
end
