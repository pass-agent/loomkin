defmodule Loomkin.Tools.VaultList do
  @moduledoc "Agent tool for listing vault entries with optional filters."

  use Jido.Action,
    name: "vault_list",
    description: "List vault entries with optional filters. Returns paths and titles.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      entry_type: [type: :string, doc: "Filter by entry type"],
      tags: [type: {:list, :string}, doc: "Filter by tags"],
      limit: [type: :integer, doc: "Max results (default: 100)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)

    opts = []
    opts = if type = param(params, :entry_type), do: [{:entry_type, type} | opts], else: opts
    opts = if tags = param(params, :tags), do: [{:tags, tags} | opts], else: opts
    opts = if limit = param(params, :limit), do: [{:limit, limit} | opts], else: opts

    results = Loomkin.Vault.list(vault_id, opts)

    if results == [] do
      {:ok, %{result: "Vault is empty (no entries found)"}}
    else
      formatted =
        results
        |> Enum.map(fn entry ->
          tags_str = if entry.tags != [], do: " [#{Enum.join(entry.tags, ", ")}]", else: ""
          "- #{entry.path} (#{entry.entry_type || "?"}) #{entry.title || "untitled"}#{tags_str}"
        end)
        |> Enum.join("\n")

      {:ok, %{result: "#{length(results)} entries:\n#{formatted}"}}
    end
  end
end
