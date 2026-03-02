defmodule Loomkin.Tools.FileWrite do
  @moduledoc "Writes content to a file, creating parent directories if needed."

  use Jido.Action,
    name: "file_write",
    description:
      "Writes content to a file. Creates parent directories if they don't exist. " <>
        "Overwrites the file if it already exists.",
    schema: [
      file_path: [type: :string, required: true, doc: "Path to the file (relative to project root)"],
      content: [type: :string, required: true, doc: "The content to write to the file"]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2]

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    file_path = param!(params, :file_path)
    content = param!(params, :content)

    full_path = safe_path!(file_path, project_path)

    full_path |> Path.dirname() |> File.mkdir_p!()

    case File.write(full_path, content) do
      :ok ->
        bytes = byte_size(content)
        {:ok, %{result: "Wrote #{bytes} bytes to #{full_path}"}}

      {:error, reason} ->
        {:error, "Failed to write #{full_path}: #{reason}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end
end
