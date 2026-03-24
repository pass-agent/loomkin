defmodule LoomkinWeb.Api.DecisionController do
  use LoomkinWeb, :controller

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.Pulse

  @doc "GET /api/v1/decisions?type=active_goals|recent_decisions|pulse|search&q=&limit="
  def index(conn, params) do
    query_type = params["type"] || "recent_decisions"
    limit = parse_int(params["limit"], 20)

    case query_type do
      "active_goals" ->
        nodes = Graph.active_goals()
        json(conn, %{type: "active_goals", nodes: serialize_nodes(nodes)})

      "recent_decisions" ->
        nodes = Graph.recent_decisions(limit)
        json(conn, %{type: "recent_decisions", nodes: serialize_nodes(nodes)})

      "pulse" ->
        report = Pulse.generate()

        json(conn, %{
          type: "pulse",
          summary: report.summary,
          health_score: report.health_score
        })

      "search" ->
        term = params["q"] || ""
        nodes = search_nodes(term, limit)
        json(conn, %{type: "search", query: term, nodes: serialize_nodes(nodes)})

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Unknown type. Use: active_goals, recent_decisions, pulse, search"
        })
    end
  end

  defp serialize_nodes(nodes) do
    Enum.map(nodes, fn n ->
      %{
        id: n.id,
        node_type: to_string(n.node_type),
        title: n.title,
        description: n.description,
        status: to_string(n.status),
        confidence: n.confidence,
        agent_name: n.agent_name,
        session_id: n.session_id,
        inserted_at: NaiveDateTime.to_iso8601(n.inserted_at)
      }
    end)
  end

  defp search_nodes(term, limit) do
    import Ecto.Query
    alias Loomkin.Schemas.DecisionNode

    pattern = "%#{term}%"

    DecisionNode
    |> where([n], like(n.title, ^pattern) or like(n.description, ^pattern))
    |> limit(^limit)
    |> order_by([n], desc: n.inserted_at)
    |> Loomkin.Repo.all()
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
