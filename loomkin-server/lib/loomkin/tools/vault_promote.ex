defmodule Loomkin.Tools.VaultPromote do
  @moduledoc "Agent tool for promoting WIP vault entries to their canonical paths after a branch merges."

  use Jido.Action,
    name: "vault_promote",
    description:
      "Promote vault entries from the wip/{branch}/ area to their canonical paths. " <>
        "Use after a feature branch merges to main. Updates status from draft to published " <>
        "and removes branch metadata. Can promote a single entry or all entries for a branch.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      branch: [type: :string, required: true, doc: "Branch name whose WIP entries to promote"],
      path: [
        type: :string,
        doc:
          "Specific WIP path to promote (e.g. wip/my-branch/specs/foo.md). If omitted, promotes all entries for the branch."
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Vault
  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.Index

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    branch = param!(params, :branch)
    specific_path = param(params, :path)

    wip_prefix = "wip/#{branch}/"

    entries =
      if specific_path do
        case Vault.read(vault_id, specific_path) do
          {:ok, entry} -> [entry]
          {:error, :not_found} -> []
        end
      else
        vault_id |> Index.list_by_prefix(wip_prefix) |> Enum.map(&schema_to_entry/1)
      end

    if entries == [] do
      {:ok, %{result: "No WIP entries found for branch: #{branch}"}}
    else
      results = Enum.map(entries, &promote_entry(vault_id, &1, wip_prefix))
      promoted = Enum.filter(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      summary =
        Enum.map_join(promoted, "\n", fn {:ok, {old, new}} -> "  #{old} -> #{new}" end)

      error_summary =
        if errors != [] do
          err_lines = Enum.map_join(errors, "\n", fn {:error, msg} -> "  #{msg}" end)
          "\nErrors:\n#{err_lines}"
        else
          ""
        end

      {:ok,
       %{
         result:
           "Promoted #{length(promoted)} entries from wip/#{branch}/:\n#{summary}#{error_summary}"
       }}
    end
  end

  defp promote_entry(vault_id, entry, wip_prefix) do
    old_path = entry.path

    if not String.starts_with?(old_path, wip_prefix) do
      {:error, "#{old_path}: not a WIP path (expected prefix #{wip_prefix})"}
    else
      canonical_path = String.replace_leading(old_path, wip_prefix, "")
      do_promote(vault_id, entry, old_path, canonical_path)
    end
  end

  defp do_promote(vault_id, entry, old_path, canonical_path) do
    # Update metadata: remove branch, set status to published
    promoted_metadata =
      entry.metadata
      |> Map.delete("branch")
      |> Map.put("status", "published")

    promoted_entry = %{
      entry
      | path: canonical_path,
        metadata: promoted_metadata
    }

    with :ok <- check_no_conflict(vault_id, canonical_path),
         {:ok, _} <- Vault.write_entry(vault_id, promoted_entry),
         :ok <- delete_wip_entry(vault_id, old_path),
         :ok <- update_links(vault_id, old_path, canonical_path) do
      {:ok, {old_path, canonical_path}}
    else
      {:error, reason} -> {:error, "#{old_path}: #{reason}"}
    end
  end

  defp check_no_conflict(vault_id, path) do
    case Index.get(vault_id, path) do
      nil -> :ok
      _exists -> {:error, "conflict — entry already exists at #{path}"}
    end
  rescue
    _ -> :ok
  end

  defp delete_wip_entry(vault_id, path) do
    case Vault.delete(vault_id, path) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "failed to delete WIP entry: #{inspect(reason)}"}
    end
  end

  defp schema_to_entry(%Loomkin.Schemas.VaultEntry{} = ve) do
    %Entry{
      vault_id: ve.vault_id,
      path: ve.path,
      title: ve.title,
      entry_type: ve.entry_type,
      body: ve.body,
      metadata: ve.metadata || %{},
      tags: ve.tags || []
    }
  end

  defp update_links(vault_id, old_path, new_path) do
    import Ecto.Query

    alias Loomkin.Repo
    alias Loomkin.Schemas.VaultLink

    # Update links where this entry is the source
    from(l in VaultLink,
      where: l.vault_id == ^vault_id and l.source_path == ^old_path
    )
    |> Repo.update_all(set: [source_path: new_path])

    # Update links where this entry is the target
    from(l in VaultLink,
      where: l.vault_id == ^vault_id and l.target_path == ^old_path
    )
    |> Repo.update_all(set: [target_path: new_path])

    :ok
  rescue
    e -> {:error, "failed to update links: #{Exception.message(e)}"}
  end
end
