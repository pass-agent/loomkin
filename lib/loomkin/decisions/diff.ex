defmodule Loomkin.Decisions.Diff do
  @moduledoc "Export and apply decision graph patches using change_id for idempotent merging."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode

  @patch_version "1.0"

  @doc """
  Export a subset of the decision graph as a JSON-serializable patch.

  Options:
    * `:team_id` - filter nodes by team_id in metadata
    * `:session_id` - filter nodes by session_id
    * `:node_ids` - explicit list of node IDs to export
    * `:author` - author name for the patch
    * `:branch` - branch label for the patch
  """
  def export_patch(opts \\ []) do
    nodes = query_nodes(opts)
    node_ids = MapSet.new(nodes, & &1.id)

    edges =
      query_edges_for_nodes(node_ids)
      |> Enum.filter(fn edge ->
        MapSet.member?(node_ids, edge.from_node_id) and
          MapSet.member?(node_ids, edge.to_node_id)
      end)

    # Build change_id lookup for edges
    change_id_by_id = Map.new(nodes, fn n -> {n.id, n.change_id} end)

    patch = %{
      "version" => @patch_version,
      "author" => Keyword.get(opts, :author),
      "branch" => Keyword.get(opts, :branch),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "nodes" => Enum.map(nodes, &serialize_node/1),
      "edges" =>
        Enum.map(edges, fn edge ->
          serialize_edge(edge, change_id_by_id)
        end)
    }

    {:ok, patch}
  end

  @doc """
  Apply a patch idempotently. Nodes with existing change_ids are skipped.

  Options:
    * `:dry_run` - if true, report counts without inserting (default: false)
  """
  def apply_patch(patch, opts \\ []) do
    case validate_patch(patch) do
      :ok -> do_apply(patch, opts)
      {:error, _} = err -> err
    end
  end

  @doc """
  Validate patch structure. Checks that all edge references point to nodes in the patch.
  """
  def validate_patch(%{"version" => "1.0", "nodes" => nodes, "edges" => edges})
      when is_list(nodes) and is_list(edges) do
    node_change_ids = MapSet.new(nodes, fn n -> n["change_id"] end)

    missing =
      Enum.flat_map(edges, fn edge ->
        from = edge["from_change_id"]
        to = edge["to_change_id"]

        missing_from = if MapSet.member?(node_change_ids, from), do: [], else: [from]
        missing_to = if MapSet.member?(node_change_ids, to), do: [], else: [to]
        missing_from ++ missing_to
      end)
      |> Enum.uniq()

    if missing == [] do
      :ok
    else
      {:error, {:dangling_edge_references, missing}}
    end
  end

  def validate_patch(_), do: {:error, :invalid_patch_format}

  # --- Private ---

  defp query_nodes(opts) do
    query = from(n in DecisionNode)

    query =
      case Keyword.get(opts, :node_ids) do
        nil -> query
        ids -> where(query, [n], n.id in ^ids)
      end

    query =
      case Keyword.get(opts, :session_id) do
        nil -> query
        sid -> where(query, [n], n.session_id == ^sid)
      end

    query =
      case Keyword.get(opts, :team_id) do
        nil -> query
        tid -> where(query, [n], fragment("? ->> 'team_id' = ?", n.metadata, ^tid))
      end

    Repo.all(query)
  end

  defp query_edges_for_nodes(node_ids) do
    ids = MapSet.to_list(node_ids)

    from(e in DecisionEdge, where: e.from_node_id in ^ids or e.to_node_id in ^ids)
    |> Repo.all()
  end

  defp serialize_node(node) do
    %{
      "change_id" => node.change_id,
      "node_type" => to_string(node.node_type),
      "title" => node.title,
      "description" => node.description,
      "status" => to_string(node.status),
      "confidence" => node.confidence,
      "metadata" => node.metadata,
      "agent_name" => node.agent_name,
      "created_at" => node.inserted_at && DateTime.to_iso8601(node.inserted_at)
    }
  end

  defp serialize_edge(edge, change_id_by_id) do
    %{
      "from_change_id" => Map.fetch!(change_id_by_id, edge.from_node_id),
      "to_change_id" => Map.fetch!(change_id_by_id, edge.to_node_id),
      "edge_type" => to_string(edge.edge_type),
      "rationale" => edge.rationale
    }
  end

  defp do_apply(patch, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    Repo.transaction(fn ->
      # Process nodes
      {nodes_added, nodes_skipped, change_id_to_db_id} =
        Enum.reduce(patch["nodes"], {0, 0, %{}}, fn node_data, {added, skipped, mapping} ->
          change_id = node_data["change_id"]

          case find_node_by_change_id(change_id) do
            nil ->
              if dry_run do
                {added + 1, skipped, Map.put(mapping, change_id, :dry_run)}
              else
                case insert_node_from_patch(node_data) do
                  {:ok, node} ->
                    {added + 1, skipped, Map.put(mapping, change_id, node.id)}

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
              end

            existing ->
              {added, skipped + 1, Map.put(mapping, change_id, existing.id)}
          end
        end)

      # Process edges
      {edges_added, edges_skipped} =
        Enum.reduce(patch["edges"], {0, 0}, fn edge_data, {added, skipped} ->
          from_id = Map.get(change_id_to_db_id, edge_data["from_change_id"])
          to_id = Map.get(change_id_to_db_id, edge_data["to_change_id"])
          edge_type = String.to_existing_atom(edge_data["edge_type"])

          cond do
            is_nil(from_id) or is_nil(to_id) ->
              {added, skipped + 1}

            dry_run ->
              {added + 1, skipped}

            edge_exists?(from_id, to_id, edge_type) ->
              {added, skipped + 1}

            true ->
              case Loomkin.Decisions.Graph.add_edge(from_id, to_id, edge_type,
                     rationale: edge_data["rationale"]
                   ) do
                {:ok, _} -> {added + 1, skipped}
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        end)

      %{
        nodes_added: nodes_added,
        nodes_skipped: nodes_skipped,
        edges_added: edges_added,
        edges_skipped: edges_skipped
      }
    end)
  end

  defp find_node_by_change_id(change_id) do
    from(n in DecisionNode, where: n.change_id == ^change_id, limit: 1)
    |> Repo.one()
  end

  defp insert_node_from_patch(data) do
    attrs = %{
      change_id: data["change_id"],
      node_type: String.to_existing_atom(data["node_type"]),
      title: data["title"],
      description: data["description"],
      status: String.to_existing_atom(data["status"] || "active"),
      confidence: data["confidence"],
      metadata: data["metadata"] || %{},
      agent_name: data["agent_name"]
    }

    %DecisionNode{}
    |> DecisionNode.changeset(attrs)
    |> Repo.insert()
  end

  defp edge_exists?(from_id, to_id, edge_type) do
    from(e in DecisionEdge,
      where:
        e.from_node_id == ^from_id and
          e.to_node_id == ^to_id and
          e.edge_type == ^edge_type,
      limit: 1
    )
    |> Repo.exists?()
  end
end
