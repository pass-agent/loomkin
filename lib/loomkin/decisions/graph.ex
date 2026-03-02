defmodule Loomkin.Decisions.Graph do
  @moduledoc "Public API for the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.{DecisionNode, DecisionEdge}

  # --- Nodes ---

  def add_node(attrs) do
    attrs = Map.put_new(attrs, :change_id, Ecto.UUID.generate())

    %DecisionNode{}
    |> DecisionNode.changeset(attrs)
    |> Repo.insert()
  end

  def get_node(id), do: Repo.get(DecisionNode, id)

  def get_node!(id), do: Repo.get!(DecisionNode, id)

  def update_node(%DecisionNode{} = node, attrs) do
    node
    |> DecisionNode.changeset(attrs)
    |> Repo.update()
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

  defp apply_node_filters(query, [_ | rest]), do: apply_node_filters(query, rest)

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

  def recent_decisions(limit \\ 10) do
    DecisionNode
    |> where([n], n.node_type in [:decision, :option])
    |> order_by([n], desc: n.inserted_at)
    |> limit(^limit)
    |> Repo.all()
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
end
