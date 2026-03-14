defmodule Loomkin.Decisions.Cascade do
  @moduledoc "Propagates uncertainty warnings downstream when a node's confidence drops below threshold."

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms

  @default_threshold 50

  @doc """
  Check a node's confidence and propagate warnings downstream if below threshold.

  Walks downstream via `:requires` and `:blocks` edges (up to `max_depth: 5`).
  For each affected downstream node, sets `metadata.upstream_uncertainty = true`
  and notifies the owning agent via PubSub.

  Options:
    * `:threshold` — confidence level below which cascade triggers (default: #{@default_threshold})

  Returns `{:ok, affected_count}` or `{:ok, :above_threshold}`.
  """
  def check_and_propagate(node_id, opts \\ []) do
    default = Loomkin.Config.get(:decisions, :cascade_threshold) || @default_threshold
    threshold = Keyword.get(opts, :threshold, default)

    case Graph.get_node(node_id) do
      nil ->
        {:error, :not_found}

      node ->
        if is_integer(node.confidence) and node.confidence < threshold do
          downstream = Graph.walk_downstream(node_id, [:requires, :blocks], max_depth: 5)
          affected = propagate(node, downstream)
          {:ok, affected}
        else
          {:ok, :above_threshold}
        end
    end
  end

  defp propagate(_source_node, []), do: 0

  defp propagate(source_node, downstream_nodes) do
    Enum.reduce(downstream_nodes, 0, fn {downstream_node, _depth, edge_type}, count ->
      # Idempotent: skip if already marked
      if downstream_node.metadata["upstream_uncertainty"] == true do
        count
      else
        metadata =
          Map.merge(downstream_node.metadata || %{}, %{"upstream_uncertainty" => true})

        case Graph.update_node(downstream_node, %{metadata: metadata}) do
          {:ok, _updated} ->
            notify_agent(source_node, downstream_node, edge_type)
            count + 1

          {:error, _reason} ->
            count
        end
      end
    end)
  end

  defp notify_agent(source_node, downstream_node, edge_type) do
    team_id = source_node.metadata["team_id"]
    agent_name = downstream_node.agent_name

    if team_id && agent_name do
      warning =
        {:confidence_warning,
         %{
           source_node_id: source_node.id,
           source_title: source_node.title,
           source_confidence: source_node.confidence,
           affected_node_id: downstream_node.id,
           affected_title: downstream_node.title,
           keeper_id: source_node.metadata["keeper_id"],
           edge_path: [edge_type]
         }}

      Comms.send_to(team_id, agent_name, warning)
    end
  end
end
