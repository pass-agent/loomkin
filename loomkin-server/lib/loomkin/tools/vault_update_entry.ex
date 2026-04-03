defmodule Loomkin.Tools.VaultUpdateEntry do
  @moduledoc "Agent tool for updating existing vault entries."

  use Jido.Action,
    name: "vault_update_entry",
    description:
      "Update an existing vault entry. Supports replacing or appending content, " <>
        "merging frontmatter, changing status, and adding/removing tags.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      path: [type: :string, required: true, doc: "Path of entry to update"],
      content: [type: :string, doc: "Replace entire body with this content"],
      append: [
        type: :string,
        doc: "Append this text to existing body (mutually exclusive with content)"
      ],
      frontmatter_updates: [
        type: :string,
        doc: "JSON string of frontmatter fields to merge into existing metadata"
      ],
      status: [type: :string, doc: "Change entry status: draft, active, archived"],
      add_tags: [type: {:list, :string}, doc: "Tags to add"],
      remove_tags: [type: {:list, :string}, doc: "Tags to remove"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Vault
  alias Loomkin.Vault.Entry

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    path = param!(params, :path)
    content = param(params, :content)
    append = param(params, :append)
    fm_json = param(params, :frontmatter_updates)
    status = param(params, :status)
    add_tags = param(params, :add_tags, [])
    remove_tags = param(params, :remove_tags, [])

    with :ok <- validate_exclusive(content, append),
         {:ok, entry} <- read_entry(vault_id, path),
         {:ok, fm_updates} <- parse_frontmatter_updates(fm_json),
         updated <-
           apply_updates(entry, content, append, fm_updates, status, add_tags, remove_tags),
         {:ok, _written} <- Vault.write_entry(vault_id, updated) do
      changes = summarize_changes(content, append, fm_updates, status, add_tags, remove_tags)

      {:ok,
       %{
         result: "Updated: #{path}\n  Changes: #{changes}"
       }}
    end
  end

  defp validate_exclusive(content, append)
       when not is_nil(content) and content != "" and not is_nil(append) and append != "" do
    {:error, "content and append are mutually exclusive — provide one or the other, not both"}
  end

  defp validate_exclusive(_content, _append), do: :ok

  defp read_entry(vault_id, path) do
    case Vault.read(vault_id, path) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, "Entry not found: #{path}"}
    end
  end

  defp parse_frontmatter_updates(nil), do: {:ok, %{}}
  defp parse_frontmatter_updates(""), do: {:ok, %{}}

  defp parse_frontmatter_updates(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "frontmatter_updates must be a JSON object"}
      {:error, _} -> {:error, "invalid JSON in frontmatter_updates"}
    end
  end

  defp apply_updates(%Entry{} = entry, content, append, fm_updates, status, add_tags, remove_tags) do
    entry
    |> apply_content(content, append)
    |> apply_frontmatter(fm_updates)
    |> apply_status(status)
    |> apply_tags(add_tags, remove_tags)
  end

  defp apply_content(entry, content, _append) when is_binary(content) and content != "" do
    %{entry | body: content}
  end

  defp apply_content(entry, _content, append) when is_binary(append) and append != "" do
    existing = entry.body || ""
    %{entry | body: existing <> "\n" <> append}
  end

  defp apply_content(entry, _content, _append), do: entry

  defp apply_frontmatter(entry, fm) when map_size(fm) == 0, do: entry

  defp apply_frontmatter(entry, fm_updates) do
    merged = Map.merge(entry.metadata || %{}, fm_updates)

    # Sync title and entry_type if updated in frontmatter
    title = Map.get(merged, "title", entry.title)
    entry_type = Map.get(merged, "type", entry.entry_type)

    %{entry | metadata: merged, title: title, entry_type: entry_type}
  end

  defp apply_status(entry, nil), do: entry
  defp apply_status(entry, ""), do: entry

  defp apply_status(entry, status) do
    metadata = Map.put(entry.metadata || %{}, "status", status)
    %{entry | metadata: metadata}
  end

  defp apply_tags(entry, add, remove) do
    current = entry.tags || []

    updated =
      current
      |> Enum.reject(&(&1 in (remove || [])))
      |> Kernel.++(add || [])
      |> Enum.uniq()

    metadata =
      if updated == [] do
        Map.delete(entry.metadata || %{}, "tags")
      else
        Map.put(entry.metadata || %{}, "tags", updated)
      end

    %{entry | tags: updated, metadata: metadata}
  end

  defp summarize_changes(content, append, fm_updates, status, add_tags, remove_tags) do
    parts = []

    parts =
      if is_binary(content) and content != "" do
        parts ++ ["content replaced"]
      else
        parts
      end

    parts =
      if is_binary(append) and append != "" do
        parts ++ ["content appended"]
      else
        parts
      end

    parts =
      if map_size(fm_updates) > 0 do
        keys = fm_updates |> Map.keys() |> Enum.join(", ")
        parts ++ ["frontmatter updated (#{keys})"]
      else
        parts
      end

    parts =
      if is_binary(status) and status != "" do
        parts ++ ["status -> #{status}"]
      else
        parts
      end

    parts =
      if is_list(add_tags) and add_tags != [] do
        parts ++ ["added tags: #{Enum.join(add_tags, ", ")}"]
      else
        parts
      end

    parts =
      if is_list(remove_tags) and remove_tags != [] do
        parts ++ ["removed tags: #{Enum.join(remove_tags, ", ")}"]
      else
        parts
      end

    if parts == [], do: "no changes", else: Enum.join(parts, "; ")
  end
end
