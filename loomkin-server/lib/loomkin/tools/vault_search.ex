defmodule Loomkin.Tools.VaultSearch do
  @moduledoc "Agent tool for full-text search across vault entries."

  use Jido.Action,
    name: "vault_search",
    description:
      "Search vault entries using full-text search. Returns ranked results. " <>
        "Supports filtering by type and tags.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      query: [type: :string, required: true, doc: "Search query text"],
      entry_type: [type: :string, doc: "Filter by entry type (note, meeting, decision, etc.)"],
      tags: [type: {:list, :string}, doc: "Filter by tags (entries must contain ALL listed tags)"],
      limit: [type: :integer, doc: "Max results to return (default: 20)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    query = param!(params, :query)

    opts = []
    opts = if type = param(params, :entry_type), do: [{:entry_type, type} | opts], else: opts
    opts = if tags = param(params, :tags), do: [{:tags, tags} | opts], else: opts
    opts = if limit = param(params, :limit), do: [{:limit, limit} | opts], else: opts

    results = Loomkin.Vault.search(vault_id, query, opts)

    if results == [] do
      {:ok, %{result: "No entries found matching '#{query}'"}}
    else
      formatted =
        results
        |> Enum.map(fn entry ->
          "- #{entry.path} (#{entry.entry_type || "unknown"}) — #{entry.title || "untitled"}"
        end)
        |> Enum.join("\n")

      {:ok, %{result: "Found #{length(results)} entries:\n#{formatted}"}}
    end
  end
end
