defmodule Loomkin.Tools.VaultRead do
  @moduledoc "Agent tool for reading vault entries by path."

  use Jido.Action,
    name: "vault_read",
    description: "Read a vault entry by path. Returns the full content including frontmatter.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      path: [type: :string, required: true, doc: "Entry path (e.g. 'notes/my-note.md')"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    path = param!(params, :path)

    case Loomkin.Vault.read(vault_id, path) do
      {:ok, entry} ->
        content = Loomkin.Vault.Parser.serialize(entry)
        tags_str = if entry.tags == [], do: "none", else: Enum.join(entry.tags, ", ")

        {:ok,
         %{
           result:
             "Entry: #{path}\nType: #{entry.entry_type || "unknown"}\nTags: #{tags_str}\n\n#{content}"
         }}

      {:error, :not_found} ->
        {:error, "Entry not found: #{path}"}
    end
  end
end
