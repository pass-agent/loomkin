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

        if team_id = get_in(node.metadata, ["team_id"]) do
          Phoenix.PubSub.broadcast(
            Loomkin.PubSub,
            "decision_graph:#{team_id}",
            {:node_added, node}
          )
        end

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
    # session_id is a :binary_id (UUID) — skip filter if the value isn't a valid UUID
    if valid_uuid?(sid) do
      query |> where([n], n.session_id == ^sid) |> apply_node_filters(rest)
    else
      apply_node_filters(query, rest)
    end
  end

  defp apply_node_filters(query, [{:team_id, team_id} | rest]) do
    query
    |> where([n], fragment("? ->> 'team_id' = ?", n.metadata, ^team_id))
    |> apply_node_filters(rest)
  end

  defp apply_node_filters(query, [{:branch, branch} | rest]) do
    query
    |> where([n], fragment("? ->> 'branch' = ?", n.metadata, ^branch))
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

  # --- Pivot Chains ---

  @doc """
  Creates an atomic pivot chain: old_node -> observation -> revisit -> new_decision.
  Supersedes the old node and broadcasts {:pivot_created, ...}.
  """
  def create_pivot_chain(old_node_id, observation_title, new_approach_title, opts \\ []) do
    Repo.transaction(fn ->
      old_node = get_node(old_node_id)

      if is_nil(old_node), do: Repo.rollback(:old_node_not_found)
      if old_node.status != :active, do: Repo.rollback(:old_node_not_active)

      base_metadata =
        Map.take(old_node.metadata || %{}, ["team_id", "keeper_id"])
        |> Map.put("agent_name", old_node.agent_name || Keyword.get(opts, :agent_name))
        |> Map.merge(Keyword.get(opts, :metadata, %{}))

      base_attrs = %{
        status: :active,
        session_id: old_node.session_id,
        agent_name: Keyword.get(opts, :agent_name, old_node.agent_name),
        metadata: base_metadata
      }

      {:ok, observation} =
        base_attrs
        |> Map.merge(%{node_type: :observation, title: observation_title})
        |> add_node()
        |> rollback_on_error()

      {:ok, revisit} =
        base_attrs
        |> Map.merge(%{node_type: :revisit, title: "Reconsidering: #{old_node.title}"})
        |> add_node()
        |> rollback_on_error()

      {:ok, decision} =
        base_attrs
        |> Map.merge(%{
          node_type: :decision,
          title: new_approach_title,
          confidence: Keyword.get(opts, :confidence)
        })
        |> add_node()
        |> rollback_on_error()

      add_edge(old_node_id, observation.id, :leads_to) |> rollback_on_error()
      add_edge(observation.id, revisit.id, :leads_to) |> rollback_on_error()
      add_edge(revisit.id, decision.id, :leads_to) |> rollback_on_error()

      add_edge(old_node_id, decision.id, :supersedes,
        rationale: "Pivoted via: #{observation_title}"
      )
      |> rollback_on_error()

      update_node(old_node, %{status: :superseded}) |> rollback_on_error()

      result = %{
        old_node: old_node,
        observation: observation,
        revisit: revisit,
        decision: decision
      }

      Phoenix.PubSub.broadcast(Loomkin.PubSub, "decision_graph", {:pivot_created, result})

      if team_id = get_in(base_metadata, ["team_id"]) do
        Phoenix.PubSub.broadcast(
          Loomkin.PubSub,
          "decision_graph:#{team_id}",
          {:pivot_created, result}
        )
      end

      result
    end)
  end

  defp rollback_on_error({:ok, _} = ok), do: ok
  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)

  # --- Subtree Merging ---

  @all_edge_types ~w(leads_to chosen rejected requires blocks enables supersedes supports revises summarizes)a

  @doc """
  Merge (copy) a subtree rooted at `source_root_id` under `target_parent_id`.

  Options:
    * `:supersede_source` - mark source nodes as superseded (default: false)
    * `:edge_type` - edge type from target parent to copied root (default: :leads_to)
    * `:prefix_titles` - string prefix for copied node titles (default: nil)
    * `:metadata_merge` - map to merge into all copied node metadata (default: %{})

  Returns `{:ok, %{merged_count: N, root_id: new_root_id, id_mapping: %{old => new}}}`.
  """
  def merge_subtree(source_root_id, target_parent_id, opts \\ []) do
    edge_type = Keyword.get(opts, :edge_type, :leads_to)
    supersede_source = Keyword.get(opts, :supersede_source, false)
    prefix = Keyword.get(opts, :prefix_titles)
    metadata_merge = Keyword.get(opts, :metadata_merge, %{})

    Repo.transaction(fn ->
      source_root = get_node(source_root_id)

      if is_nil(source_root), do: Repo.rollback(:source_not_found)
      if is_nil(get_node(target_parent_id)), do: Repo.rollback(:target_not_found)

      # Collect all downstream nodes (source root + descendants)
      downstream = walk_downstream(source_root_id, @all_edge_types, max_depth: 100)
      all_nodes = [source_root | Enum.map(downstream, fn {node, _d, _e} -> node end)]
      node_ids = MapSet.new(all_nodes, & &1.id)

      # Build ID mapping: old_id -> new_id
      id_mapping =
        Map.new(all_nodes, fn node -> {node.id, Ecto.UUID.generate()} end)

      # Copy nodes
      for node <- all_nodes do
        new_id = Map.fetch!(id_mapping, node.id)
        title = if prefix, do: "#{prefix}#{node.title}", else: node.title
        merged_meta = Map.merge(node.metadata || %{}, metadata_merge)

        attrs = %{
          node_type: node.node_type,
          title: title,
          description: node.description,
          status: node.status,
          confidence: node.confidence,
          metadata: merged_meta,
          agent_name: node.agent_name,
          session_id: node.session_id,
          change_id: Ecto.UUID.generate()
        }

        case %DecisionNode{id: new_id}
             |> DecisionNode.changeset(attrs)
             |> Repo.insert() do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      # Collect edges where both endpoints are in the subtree
      all_edges =
        Enum.flat_map(all_nodes, fn node ->
          list_edges(from_node_id: node.id)
        end)

      internal_edges =
        Enum.filter(all_edges, fn edge ->
          MapSet.member?(node_ids, edge.from_node_id) and
            MapSet.member?(node_ids, edge.to_node_id)
        end)
        |> Enum.uniq_by(& &1.id)

      # Recreate internal edges with mapped IDs
      for edge <- internal_edges do
        new_from = Map.fetch!(id_mapping, edge.from_node_id)
        new_to = Map.fetch!(id_mapping, edge.to_node_id)

        case add_edge(new_from, new_to, edge.edge_type,
               rationale: edge.rationale,
               weight: edge.weight
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      # Link target parent to copied root
      new_root_id = Map.fetch!(id_mapping, source_root_id)

      case add_edge(target_parent_id, new_root_id, edge_type) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      # Optionally supersede source nodes
      if supersede_source do
        for node <- all_nodes do
          case update_node(node, %{status: :superseded}) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end

      %{
        merged_count: length(all_nodes),
        root_id: new_root_id,
        id_mapping: id_mapping
      }
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

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  defp valid_uuid?(value) when is_binary(value), do: Regex.match?(@uuid_regex, value)
  defp valid_uuid?(_), do: false
end
