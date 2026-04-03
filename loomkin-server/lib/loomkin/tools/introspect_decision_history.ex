defmodule Loomkin.Tools.IntrospectDecisionHistory do
  @moduledoc "Tool for agents to examine their own decision history."

  use Jido.Action,
    name: "introspect_decision_history",
    description:
      "Examine your own decision history from the decision graph. " <>
        "Use to understand why past decisions were made, detect circular reasoning, " <>
        "or trace the chain of assumptions and rationale that led to the current state.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query: [
        type: :string,
        required: true,
        doc:
          "What to introspect — e.g. 'Why did I choose approach X?', " <>
            "'What decisions led to current state?', 'Show recent decisions'"
      ],
      limit: [type: :integer, doc: "Maximum decisions to return (default 15)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Decisions.Graph

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    query = param!(params, :query)
    limit = param(params, :limit, 15)
    agent_name = param(context, :agent_name, nil)

    nodes = Graph.recent_decisions(limit, team_id: team_id)

    nodes =
      if agent_name do
        Enum.filter(nodes, fn n ->
          n.agent_name == to_string(agent_name) or is_nil(n.agent_name)
        end)
      else
        nodes
      end

    if nodes == [] do
      {:ok, %{result: "No decision history found for this team."}}
    else
      history = format_decision_history(nodes, query)
      {:ok, %{result: history}}
    end
  end

  defp format_decision_history(nodes, query) do
    header = "Decision history (query: \"#{String.slice(query, 0, 60)}\"):\n\n"

    entries =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        conf = if node.confidence, do: " confidence=#{node.confidence}%", else: ""

        desc =
          if node.description,
            do: "\n   Rationale: #{String.slice(node.description, 0, 200)}",
            else: ""

        meta_agent = get_in(node.metadata, ["agent_name"]) || node.agent_name || "unknown"
        time = Calendar.strftime(node.inserted_at, "%Y-%m-%d %H:%M:%S")

        "#{i}. [#{node.node_type}] #{node.title}#{conf}" <>
          "\n   Status: #{node.status} | Agent: #{meta_agent} | Time: #{time}" <>
          desc
      end)

    analysis = analyze_patterns(nodes)

    header <> entries <> "\n\n" <> analysis
  end

  defp analyze_patterns(nodes) do
    titles = Enum.map(nodes, & &1.title)
    unique_titles = Enum.uniq(titles)

    repeated =
      titles
      |> Enum.frequencies()
      |> Enum.filter(fn {_title, count} -> count > 1 end)

    lines = ["--- Pattern Analysis ---"]

    lines =
      if repeated != [] do
        repeated_str =
          Enum.map_join(repeated, ", ", fn {title, count} ->
            "\"#{String.slice(title, 0, 40)}\" (#{count}x)"
          end)

        lines ++
          ["WARNING: Repeated decisions detected: #{repeated_str}. Possible circular reasoning."]
      else
        lines ++ ["No repeated decisions detected."]
      end

    lines =
      lines ++
        [
          "Total decisions: #{length(nodes)}",
          "Unique decisions: #{length(unique_titles)}",
          "Active: #{Enum.count(nodes, &(&1.status == :active))}",
          "Superseded: #{Enum.count(nodes, &(&1.status == :superseded))}"
        ]

    avg_confidence =
      nodes
      |> Enum.filter(& &1.confidence)
      |> case do
        [] -> nil
        with_conf -> Enum.sum(Enum.map(with_conf, & &1.confidence)) / length(with_conf)
      end

    lines =
      if avg_confidence do
        lines ++ ["Average confidence: #{Float.round(avg_confidence, 1)}%"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end
end
