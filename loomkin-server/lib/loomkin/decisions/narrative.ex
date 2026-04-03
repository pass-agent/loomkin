defmodule Loomkin.Decisions.Narrative do
  @moduledoc "Builds narrative timelines from the decision graph."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode

  def for_session(nil), do: []

  def for_session(session_id, opts \\ []) do
    exclude_auto_logged = Keyword.get(opts, :exclude_auto_logged, true)

    case Ecto.UUID.dump(session_id) do
      {:ok, _bin} ->
        DecisionNode
        |> where([n], n.session_id == ^session_id)
        |> maybe_exclude_auto_logged(exclude_auto_logged)
        |> order_by([n], asc: n.inserted_at)
        |> Repo.all()

      :error ->
        []
    end
  end

  defp maybe_exclude_auto_logged(query, false), do: query

  defp maybe_exclude_auto_logged(query, true) do
    where(query, [n], fragment("(?->>'auto_logged')::boolean IS NOT TRUE", n.metadata))
  end

  def for_goal(goal_id) do
    collect_tree([goal_id], MapSet.new(), [])
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp collect_tree([], _visited, acc), do: acc

  defp collect_tree([id | rest], visited, acc) do
    if MapSet.member?(visited, id) do
      collect_tree(rest, visited, acc)
    else
      visited = MapSet.put(visited, id)

      case Repo.get(DecisionNode, id) do
        nil ->
          collect_tree(rest, visited, acc)

        node ->
          child_ids =
            DecisionEdge
            |> where([e], e.from_node_id == ^id)
            |> select([e], e.to_node_id)
            |> Repo.all()

          collect_tree(child_ids ++ rest, visited, [node | acc])
      end
    end
  end

  def format_timeline(entries) do
    entries
    |> Enum.map(fn node ->
      ts = Calendar.strftime(node.inserted_at, "%Y-%m-%d %H:%M")
      status = if node.status != :active, do: " [#{node.status}]", else: ""
      conf = if node.confidence, do: " (confidence: #{node.confidence}%)", else: ""
      desc = if node.description, do: "\n  #{node.description}", else: ""

      "[#{ts}] #{node.node_type}: #{node.title}#{status}#{conf}#{desc}"
    end)
    |> Enum.join("\n")
  end
end
