defmodule Loomkin.Tools.VaultLink do
  @moduledoc "Agent tool for managing relationships between vault entries."

  use Jido.Action,
    name: "vault_link",
    description:
      "Create or remove a link between two vault entries. " <>
        "Link types: wiki_link (default), parent, related, blocks, follows_up, decides.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      source_path: [type: :string, required: true, doc: "Source entry path"],
      target_path: [type: :string, required: true, doc: "Target entry path"],
      link_type: [
        type: :string,
        doc:
          "Link type: wiki_link, parent, related, blocks, follows_up, decides (default: wiki_link)"
      ],
      display_text: [type: :string, doc: "Display text for wiki link rendering"],
      remove: [type: :boolean, doc: "Set true to remove the link instead of creating it"]
    ]

  import Ecto.Query
  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultLink, as: VaultLinkSchema
  alias Loomkin.Vault.Index

  @valid_link_types ~w(wiki_link parent related blocks follows_up decides)

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    source_path = param!(params, :source_path)
    target_path = param!(params, :target_path)
    link_type_str = param(params, :link_type, "wiki_link")
    display_text = param(params, :display_text)
    remove = param(params, :remove, false)

    with :ok <- validate_link_type(link_type_str),
         :ok <- validate_entry_exists(vault_id, source_path, "source"),
         :ok <- validate_entry_exists(vault_id, target_path, "target") do
      link_type = String.to_existing_atom(link_type_str)

      if remove do
        remove_link(vault_id, source_path, target_path, link_type)
      else
        create_link(vault_id, source_path, target_path, link_type, display_text)
      end
    end
  end

  defp validate_link_type(type) when type in @valid_link_types, do: :ok

  defp validate_link_type(type) do
    {:error, "Invalid link_type: #{type}. Must be one of: #{Enum.join(@valid_link_types, ", ")}"}
  end

  defp validate_entry_exists(vault_id, path, label) do
    case Index.get(vault_id, path) do
      nil -> {:error, "#{label} entry not found: #{path}"}
      _entry -> :ok
    end
  end

  defp create_link(vault_id, source_path, target_path, link_type, display_text) do
    attrs = %{
      vault_id: vault_id,
      source_path: source_path,
      target_path: target_path,
      link_type: link_type,
      display_text: display_text
    }

    case %VaultLinkSchema{} |> VaultLinkSchema.changeset(attrs) |> Repo.insert() do
      {:ok, _link} ->
        {:ok,
         %{
           result: "Linked: #{source_path} -> #{target_path} (#{link_type})"
         }}

      {:error, changeset} ->
        {:error, "Failed to create link: #{inspect(changeset.errors)}"}
    end
  end

  defp remove_link(vault_id, source_path, target_path, link_type) do
    query =
      from(l in VaultLinkSchema,
        where:
          l.vault_id == ^vault_id and
            l.source_path == ^source_path and
            l.target_path == ^target_path and
            l.link_type == ^link_type
      )

    case Repo.delete_all(query) do
      {0, _} ->
        {:error, "No matching link found to remove"}

      {count, _} ->
        {:ok,
         %{
           result: "Removed #{count} link(s): #{source_path} -> #{target_path} (#{link_type})"
         }}
    end
  end
end
