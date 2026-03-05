defmodule Loomkin.Decisions.Graph do
  @moduledoc "Public API for the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Decisions.Cascade
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode

  # --- Nodes ---

  def add_node(attrs) do
    attrs = Map.put_new(attrs, :change_id, Ecto.UUID.generate())

    case %DecisionNode{}
         |> DecisionNode.changeset(attrs)
         |> Repo.insert() do
      {:ok, node} ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, "decision_graph", {:node_added, node})
        {:ok, node}

      error ->
        error
    end
  end

  def get_node(id), do: Repo.get(DecisionNode, id)

  def get_node!(id), do: Repo.get!(DecisionNode, id)

  def update_node(%DecisionNode{} = node, attrs) do
    case node |> DecisionNode.changeset(attrs) |> Repo.update() do
      {:ok, updated_node} ->
        if Map.has_key?(attrs, :confidence), do: Cascade.check_and_propagate(updated_node.id)
        {:ok, updated_node}

      error ->
        error
    end
  end

  def update_node(id, attrs) when is_binary(id) do
    case get_node(id) do
      nil -> {:error, :not_found}
      node -> update_node(node, attrs)
    end
  end

  def delete_node(id) when is_binary(id) do
    case get_node(id) do
      nil -> {:error, :not_found}
      node -> Repo.delete(node)
    end
  end

  def list_nodes(filters \\ []) do
    DecisionNode
    |> apply_node_filters(filters)
    |> Repo.all()
  end

  defp apply_node_filters(query, []), do: query

  defp apply_node_filters(query, [{:node_type, type} | rest]) do
    query |> where([n], n.node_type == ^type) |> apply_node_filters(rest)
  end

  defp apply_node_filters(query, [{:status, status} | rest]) do
    query |> where([n], n.status == ^status) |> apply_node_filters(rest)
  end

  defp apply_node_filters(query, [{:session_id, sid} | rest]) do
    query |> where([n], n.session_id == ^sid) |> apply_node_filters(rest)
  end

  defp apply_node_filters(query, [{:team_id, team_id} | rest]) do
    query
    |> where([n], fragment("? ->> 'team_id' = ?", n.metadata, ^team_id))
    |> apply_node_filters(rest)
  end

  defp apply_node_filters(query, [{:cross_session, true} | rest]) do
    apply_node_filters(query, rest)
  end

  defp apply_node_filters(query, [_ | rest]), do: apply_node_filters(query, rest)

  @doc "Creates a node with keeper_id in metadata for two-tier retrieval."
  def add_node_with_keeper(attrs, keeper_id) when is_binary(keeper_id) do
    metadata = Map.get(attrs, :metadata, %{}) |> Map.put("keeper_id", keeper_id)
    attrs |> Map.put(:metadata, metadata) |> add_node()
  end

  # --- Edges ---

  def add_edge(from_id, to_id, edge_type, opts \\ []) do
    attrs = %{
      from_node_id: from_id,
      to_node_id: to_id,
      edge_type: edge_type,
      change_id: Ecto.UUID.generate(),
      rationale: Keyword.get(opts, :rationale),
      weight: Keyword.get(opts, :weight)
    }

    %DecisionEdge{}
    |> DecisionEdge.changeset(attrs)
    |> Repo.insert()
  end

  def list_edges(filters \\ []) do
    DecisionEdge
    |> apply_edge_filters(filters)
    |> Repo.all()
  end

  defp apply_edge_filters(query, []), do: query

  defp apply_edge_filters(query, [{:edge_type, types} | rest]) when is_list(types) do
    query |> where([e], e.edge_type in ^types) |> apply_edge_filters(rest)
  end

  defp apply_edge_filters(query, [{:edge_type, type} | rest]) do
    query |> where([e], e.edge_type == ^type) |> apply_edge_filters(rest)
  end

  defp apply_edge_filters(query, [{:from_node_id, id} | rest]) do
    query |> where([e], e.from_node_id == ^id) |> apply_edge_filters(rest)
  end

  defp apply_edge_filters(query, [{:to_node_id, id} | rest]) do
    query |> where([e], e.to_node_id == ^id) |> apply_edge_filters(rest)
  end

  defp apply_edge_filters(query, [_ | rest]), do: apply_edge_filters(query, rest)

  # --- Convenience ---

  def active_goals do
    list_nodes(node_type: :goal, status: :active)
  end

  def recent_decisions(limit \\ 10, opts \\ []) do
    query =
      DecisionNode
      |> where([n], n.node_type in [:decision, :option])
      |> order_by([n], desc: n.inserted_at)
      |> limit(^limit)

    query =
      case Keyword.get(opts, :team_id) do
        nil -> query
        team_id -> where(query, [n], fragment("? ->> 'team_id' = ?", n.metadata, ^team_id))
      end

    Repo.all(query)
  end

  def supersede(old_node_id, new_node_id, rationale) do
    Repo.transaction(fn ->
      case add_edge(old_node_id, new_node_id, :supersedes, rationale: rationale) do
        {:ok, edge} ->
          case update_node(old_node_id, %{status: :superseded}) do
            {:ok, _node} -> edge
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # --- Edge Walking ---

  @doc "Walk downstream from a node through specific edge types. Returns [{node, depth, edge_type}]."
  def walk_downstream(node_id, edge_types, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 5)
    edge_types = List.wrap(edge_types)

    {results, _visited} =
      do_walk(node_id, edge_types, max_depth, 1, :downstream, MapSet.new(), [])

    results
  end

  @doc "Walk upstream (reverse edges) to find ancestors. Returns [{node, depth, edge_type}]."
  def walk_upstream(node_id, edge_types, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 5)
    edge_types = List.wrap(edge_types)
    {results, _visited} = do_walk(node_id, edge_types, max_depth, 1, :upstream, MapSet.new(), [])
    results
  end

  @doc "Find nodes connected in either direction, single hop."
  def connected_nodes(node_id, edge_types) do
    edge_types = List.wrap(edge_types)
    downstream = walk_downstream(node_id, edge_types, max_depth: 1)
    upstream = walk_upstream(node_id, edge_types, max_depth: 1)
    Enum.uniq_by(downstream ++ upstream, fn {node, _depth, _type} -> node.id end)
  end

  defp do_walk(_node_id, _edge_types, max_depth, current_depth, _direction, visited, acc)
       when current_depth > max_depth,
       do: {acc, visited}

  defp do_walk(node_id, edge_types, max_depth, current_depth, direction, visited, acc) do
    if MapSet.member?(visited, node_id) do
      {acc, visited}
    else
      visited = MapSet.put(visited, node_id)

      edges =
        case direction do
          :downstream -> list_edges(from_node_id: node_id, edge_type: edge_types)
          :upstream -> list_edges(to_node_id: node_id, edge_type: edge_types)
        end

      {nodes, next_ids} =
        Enum.reduce(edges, {[], []}, fn edge, {nodes_acc, ids_acc} ->
          next_id =
            case direction do
              :downstream -> edge.to_node_id
              :upstream -> edge.from_node_id
            end

          if MapSet.member?(visited, next_id) do
            {nodes_acc, ids_acc}
          else
            case get_node(next_id) do
              nil ->
                {nodes_acc, ids_acc}

              node ->
                {[{node, current_depth, edge.edge_type} | nodes_acc], [next_id | ids_acc]}
            end
          end
        end)

      # Thread visited set across sibling branches to prevent duplicates on diamond paths
      {deeper, visited} =
        Enum.reduce(next_ids, {[], visited}, fn id, {deep_acc, vis} ->
          {results, vis} =
            do_walk(id, edge_types, max_depth, current_depth + 1, direction, vis, [])

          {deep_acc ++ results, vis}
        end)

      {acc ++ Enum.reverse(nodes) ++ deeper, visited}
    end
  end
end
