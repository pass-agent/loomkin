defmodule Loomkin.Tools.IntrospectFailurePatterns do
  @moduledoc "Tool for agents to examine their own failure patterns from failure memory keepers."

  use Jido.Action,
    name: "introspect_failure_patterns",
    description:
      "Examine your past failure patterns from failure memory keepers. " <>
        "Use to understand what errors you've hit before, what patterns emerge, " <>
        "and what fixes worked. Helps avoid repeating known mistakes.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query: [
        type: :string,
        doc:
          "Optional focus area — e.g. 'compile errors', 'test failures'. " <>
            "Omit for a general failure summary."
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.ContextRetrieval

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    query = param(params, :query)
    agent_name = param(context, :agent_name)

    search_query = build_search_query(agent_name, query)

    keepers =
      ContextRetrieval.search(team_id, search_query)
      |> Enum.filter(fn k ->
        String.starts_with?(k.topic, "failures:")
      end)

    if keepers == [] do
      {:ok, %{result: "No failure patterns found. No past errors recorded for this team."}}
    else
      case ContextRetrieval.synthesize(team_id, search_query,
             agent_name: to_string(agent_name || "unknown")
           ) do
        {:ok, summary} when is_binary(summary) and summary != "" ->
          result = format_failure_report(keepers, summary, agent_name)
          {:ok, %{result: result}}

        _ ->
          result = format_keeper_list(keepers, agent_name)
          {:ok, %{result: result}}
      end
    end
  end

  defp build_search_query(agent_name, nil) do
    "failures:#{agent_name || "all"}"
  end

  defp build_search_query(agent_name, query) do
    "failures:#{agent_name || "all"} #{query}"
  end

  defp format_failure_report(keepers, summary, agent_name) do
    header = "Failure pattern analysis"
    header = if agent_name, do: "#{header} for #{agent_name}", else: header

    """
    #{header} (#{length(keepers)} failure record(s)):

    #{summary}

    ---
    Source keepers: #{Enum.map_join(keepers, ", ", & &1.topic)}
    """
    |> String.trim()
  end

  defp format_keeper_list(keepers, agent_name) do
    header = "Failure records found"
    header = if agent_name, do: "#{header} for #{agent_name}", else: header

    entries =
      Enum.map_join(keepers, "\n", fn k ->
        "- [#{k.id}] topic=#{k.topic} source=#{k.source_agent} tokens=#{k.token_count}"
      end)

    "#{header} (#{length(keepers)} record(s)):\n#{entries}\n\nUse context_retrieve with a specific keeper_id for full details."
  end
end
