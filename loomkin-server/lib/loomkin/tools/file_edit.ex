defmodule Loomkin.Tools.FileEdit do
  @moduledoc "Performs exact string replacements in a file."

  use Jido.Action,
    name: "file_edit",
    description:
      "Performs exact string replacement in a file. By default, old_string must appear " <>
        "exactly once in the file (to prevent ambiguous edits). Set replace_all to true " <>
        "to replace every occurrence.",
    schema: [
      file_path: [
        type: :string,
        required: true,
        doc: "Path to the file (relative to project root)"
      ],
      old_string: [type: :string, required: true, doc: "The exact text to find and replace"],
      new_string: [type: :string, required: true, doc: "The text to replace it with"],
      replace_all: [
        type: :boolean,
        doc: "Replace all occurrences (default: false, requires unique match)"
      ]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2, param: 3]

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    file_path = param!(params, :file_path)
    old_string = param!(params, :old_string)
    new_string = param!(params, :new_string)
    replace_all = param(params, :replace_all, false)

    full_path = safe_path!(file_path, project_path)

    warning = read_before_write_warning(full_path, context)

    with {:ok, content} <- read_file(full_path),
         :ok <- validate_match(content, old_string, replace_all),
         new_content <- apply_replacement(content, old_string, new_string, replace_all),
         :ok <- File.write(full_path, new_content) do
      count = occurrence_count(content, old_string)
      result_msg = "Replaced #{count} occurrence(s) in #{full_path}"
      {:ok, %{result: warning <> result_msg}}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp read_before_write_warning(full_path, context) do
    read_files = Map.get(context, :read_files, nil)

    cond do
      # No tracking available (e.g. direct tool call outside agent loop)
      is_nil(read_files) ->
        ""

      MapSet.member?(read_files, full_path) ->
        ""

      true ->
        "Warning: You are editing a file you haven't read yet. " <>
          "Consider reading it first to understand the existing code.\n"
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
    end
  end

  defp validate_match(content, old_string, replace_all) do
    count = occurrence_count(content, old_string)

    cond do
      count == 0 ->
        {:error,
         "old_string not found in file. Make sure the text matches exactly (including whitespace and indentation)."}

      count > 1 and not replace_all ->
        {:error,
         "old_string appears #{count} times. Use replace_all: true to replace all, or provide a larger unique string."}

      true ->
        :ok
    end
  end

  defp apply_replacement(content, old_string, new_string, true) do
    String.replace(content, old_string, new_string)
  end

  defp apply_replacement(content, old_string, new_string, false) do
    String.replace(content, old_string, new_string, global: false)
  end

  defp occurrence_count(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
