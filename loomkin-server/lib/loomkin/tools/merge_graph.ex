defmodule Loomkin.Tools.MergeGraph do
  @moduledoc "Tool for merging a decision subtree into another part of the graph."

  use Jido.Action,
    name: "merge_graph",
    description:
      "Merge a decision subtree into another part of the graph. Use after speculative work succeeds to consolidate results.",
    schema: [
      source_root_id: [type: :string, required: true, doc: "Root of the subtree to merge"],
      target_parent_id: [type: :string, required: true, doc: "Node to merge under"],
      supersede_source: [
        type: :boolean,
        doc: "Mark source nodes as superseded (default: false)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Decisions.Graph

  @impl true
  def run(params, _context) do
    source_root_id = param!(params, :source_root_id)
    target_parent_id = param!(params, :target_parent_id)
    supersede_source = param(params, :supersede_source, false)

    case Graph.merge_subtree(source_root_id, target_parent_id, supersede_source: supersede_source) do
      {:ok, result} ->
        {:ok,
         %{
           result:
             "Merged #{result.merged_count} nodes under #{target_parent_id}. New root: #{result.root_id}"
         }}

      {:error, :source_not_found} ->
        {:error, "Source root node not found: #{source_root_id}"}

      {:error, :target_not_found} ->
        {:error, "Target parent node not found: #{target_parent_id}"}

      {:error, reason} ->
        {:error, "Merge failed: #{inspect(reason)}"}
    end
  end
end
