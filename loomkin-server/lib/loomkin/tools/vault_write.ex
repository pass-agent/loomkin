defmodule Loomkin.Tools.VaultWrite do
  @moduledoc "Agent tool for writing content to a vault path."

  use Jido.Action,
    name: "vault_write",
    description:
      "Write raw markdown content to a vault path. Overwrites if exists. " <>
        "Content should include YAML frontmatter for structured entries.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      path: [type: :string, required: true, doc: "Entry path (e.g. 'notes/my-note.md')"],
      content: [
        type: :string,
        required: true,
        doc: "Full markdown content (including YAML frontmatter if desired)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    path = param!(params, :path)
    content = param!(params, :content)

    case Loomkin.Vault.write(vault_id, path, content) do
      {:ok, entry} ->
        {:ok,
         %{
           result:
             "Written: #{path}\nTitle: #{entry.title || "untitled"}\nType: #{entry.entry_type || "unknown"}"
         }}

      {:error, reason} ->
        {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end
end
