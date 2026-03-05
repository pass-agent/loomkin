defmodule Loomkin.Tools.DecisionQuery do
  @moduledoc "Tool for querying the decision graph."

  use Jido.Action,
    name: "decision_query",
    description:
      "Query the decision graph for active goals, recent decisions, pulse reports, or search by keyword",
    schema: [
      query_type: [
        type: :string,
        required: true,
        doc: "Type of query to run (active_goals, recent_decisions, pulse, search)"
      ],
      search_term: [type: :string, doc: "Search term for 'search' query type"],
      limit: [type: :integer, doc: "Maximum results to return (default 10)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.Pulse

  @impl true
  def run(params, _context) do
    query_type = param!(params, :query_type)
    limit = param(params, :limit, 10)

    case query_type do
      "active_goals" ->
        goals = Graph.active_goals()
        {:ok, %{result: format_nodes("Active Goals", goals)}}

      "recent_decisions" ->
        decisions = Graph.recent_decisions(limit)
        {:ok, %{result: format_nodes("Recent Decisions", decisions)}}

      "pulse" ->
        report = Pulse.generate()
        {:ok, %{result: report.summary}}

      "search" ->
        search_term = param(params, :search_term, "")
        results = search_nodes(search_term, limit)
        {:ok, %{result: format_nodes("Search Results for '#{search_term}'", results)}}

      other ->
        {:error,
         "Unknown query_type '#{other}'. Valid types: active_goals, recent_decisions, pulse, search"}
    end
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

  defp format_nodes(heading, []) do
    "#{heading}: None found."
  end

  defp format_nodes(heading, nodes) do
    items =
      Enum.map_join(nodes, "\n", fn n ->
        conf = if n.confidence, do: " (confidence: #{n.confidence}%)", else: ""
        "- [#{n.node_type}] #{n.title}#{conf} (#{n.status}, id: #{n.id})"
      end)

    "#{heading}:\n#{items}"
  end
end
