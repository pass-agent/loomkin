defmodule Loomkin.Tools.QueryBacklog do
  @moduledoc """
  Agent tool for querying the persistent backlog.

  Supports multiple query modes so agents can find relevant work items:
  - actionable: todo + in_progress items (what to work on next)
  - by_status: filter by lifecycle state
  - by_epic: roadmap view grouped by epic
  - by_category: filter by category
  - by_team: items assigned to a specific team
  - search: full-text search
  - summary: counts by status
  """

  use Jido.Action,
    name: "query_backlog",
    description:
      "Query the persistent backlog/roadmap. Returns prioritized work items, " <>
        "filtered by status, category, epic, or search term. Use 'actionable' " <>
        "to see what to work on next, 'summary' for a quick overview.",
    schema: [
      query_type: [
        type: :string,
        required: true,
        doc: "Query type: actionable, by_status, by_epic, by_category, by_team, search, summary"
      ],
      status: [type: :string, doc: "Status filter for 'by_status' query"],
      category: [type: :string, doc: "Category filter for 'by_category' query"],
      epic: [type: :string, doc: "Epic filter (unused — by_epic shows all epics grouped)"],
      team_id: [type: :string, doc: "Team ID for 'by_team' query"],
      search_term: [type: :string, doc: "Search term for 'search' query"],
      limit: [type: :string, doc: "Max results to return (default 20)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Backlog

  @impl true
  def run(params, _context) do
    query_type = param!(params, :query_type)
    limit = parse_int(param(params, :limit), 20)

    case query_type do
      "actionable" ->
        items = Backlog.list_actionable(limit: limit)
        {:ok, %{result: format_items("Actionable Items", items)}}

      "by_status" ->
        status_str = param(params, :status) || "todo"

        case safe_to_atom(status_str, ~w(icebox todo in_progress done blocked cancelled)) do
          {:ok, status} ->
            items = Backlog.list_by_status(status, limit: limit)
            {:ok, %{result: format_items("Items (#{status})", items)}}

          :error ->
            {:error, "Invalid status: #{status_str}"}
        end

      "by_epic" ->
        grouped = Backlog.list_by_epic()
        {:ok, %{result: format_grouped("Backlog by Epic", grouped)}}

      "by_category" ->
        category = param(params, :category) || ""

        if category == "" do
          {:error, "category parameter required for by_category query"}
        else
          items = Backlog.list_by_category(category, limit: limit)
          {:ok, %{result: format_items("Items in '#{category}'", items)}}
        end

      "by_team" ->
        team_id = param(params, :team_id) || ""

        if team_id == "" do
          {:error, "team_id parameter required for by_team query"}
        else
          items = Backlog.list_by_team(team_id, limit: limit)
          {:ok, %{result: format_items("Items for team #{team_id}", items)}}
        end

      "search" ->
        term = param(params, :search_term) || ""

        if term == "" do
          {:error, "search_term parameter required for search query"}
        else
          items = Backlog.search(term, limit: limit)
          {:ok, %{result: format_items("Search results for '#{term}'", items)}}
        end

      "summary" ->
        summary = Backlog.get_summary()
        {:ok, %{result: format_summary(summary)}}

      other ->
        {:error,
         "Unknown query_type '#{other}'. Valid: actionable, by_status, by_epic, by_category, by_team, search, summary"}
    end
  end

  defp format_items(_heading, []), do: "No items found."

  defp format_items(heading, items) do
    lines =
      Enum.map_join(items, "\n", fn item ->
        priority_marker = String.duplicate("!", max(6 - item.priority, 1))
        epic_tag = if item.epic, do: " [#{item.epic}]", else: ""
        cat_tag = if item.category, do: " (#{item.category})", else: ""
        scope_tag = " ~#{item.scope_estimate}"

        "- #{priority_marker} [#{item.status}] #{item.title}#{epic_tag}#{cat_tag}#{scope_tag} (id: #{item.id})"
      end)

    "#{heading} (#{length(items)} items):\n#{lines}"
  end

  defp format_grouped(_heading, grouped) when map_size(grouped) == 0 do
    "No items with epic assignments found."
  end

  defp format_grouped(heading, grouped) do
    sections =
      Enum.map_join(grouped, "\n\n", fn {epic, items} ->
        lines =
          Enum.map_join(items, "\n", fn item ->
            "  - [#{item.status}] P#{item.priority} #{item.title}"
          end)

        "## #{epic} (#{length(items)} items)\n#{lines}"
      end)

    "#{heading}:\n\n#{sections}"
  end

  defp format_summary(summary) do
    total = Enum.reduce(summary, 0, fn {_k, v}, acc -> acc + v end)

    lines =
      Enum.map_join(
        [:todo, :in_progress, :blocked, :done, :cancelled, :icebox],
        "\n",
        fn status ->
          count = Map.get(summary, status, 0)
          "  #{status}: #{count}"
        end
      )

    "Backlog Summary (#{total} total items):\n#{lines}"
  end

  defp safe_to_atom(str, valid_strings) when is_binary(str) do
    if str in valid_strings do
      {:ok, String.to_existing_atom(str)}
    else
      :error
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
