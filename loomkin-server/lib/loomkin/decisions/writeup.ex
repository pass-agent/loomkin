defmodule Loomkin.Decisions.Writeup do
  @moduledoc "Generates PR writeup Markdown from the decision graph."

  alias Loomkin.Decisions.Graph

  @all_edge_types [
    :leads_to,
    :chosen,
    :rejected,
    :requires,
    :blocks,
    :enables,
    :supersedes,
    :supports,
    :revises,
    :summarizes
  ]

  @doc """
  Generate a PR writeup from the decision graph.

  Options:
    - :title - PR title (default "Pull Request")
    - :team_id - scope to a team
    - :session_id - scope to a session
    - :root_ids - BFS from specific root nodes
    - :include_test_plan - include test plan section (default true)
  """
  def generate(opts \\ []) do
    title = Keyword.get(opts, :title, "Pull Request")
    include_test_plan = Keyword.get(opts, :include_test_plan, true)

    nodes = collect_nodes(opts)
    edges = collect_edges(nodes)
    grouped = Enum.group_by(nodes, & &1.node_type)

    sections =
      [
        "# #{title}\n",
        summary_section(grouped),
        decisions_section(grouped, edges),
        implementation_section(grouped),
        results_section(grouped),
        prior_attempts_section(nodes),
        if(include_test_plan, do: test_plan_section(), else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {:ok, sections}
  end

  defp collect_nodes(opts) do
    root_ids = Keyword.get(opts, :root_ids)
    team_id = Keyword.get(opts, :team_id)
    session_id = Keyword.get(opts, :session_id)

    cond do
      root_ids && root_ids != [] ->
        root_ids
        |> Enum.flat_map(fn root_id ->
          root_node = Graph.get_node(root_id)
          downstream = Graph.walk_downstream(root_id, @all_edge_types, max_depth: 10)
          downstream_nodes = Enum.map(downstream, fn {node, _depth, _type} -> node end)
          if root_node, do: [root_node | downstream_nodes], else: downstream_nodes
        end)
        |> Enum.uniq_by(& &1.id)

      team_id ->
        Graph.list_nodes(team_id: team_id, limit: :none)

      session_id ->
        Graph.list_nodes(session_id: session_id, limit: :none)

      true ->
        Graph.list_nodes(status: :active, limit: :none)
    end
  end

  defp collect_edges(nodes) do
    node_ids = MapSet.new(nodes, & &1.id)

    nodes
    |> Enum.flat_map(fn node ->
      Graph.list_edges(from_node_id: node.id)
    end)
    |> Enum.filter(fn edge ->
      MapSet.member?(node_ids, edge.from_node_id) and
        MapSet.member?(node_ids, edge.to_node_id)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp summary_section(grouped) do
    goals = Map.get(grouped, :goal, [])
    observations = Map.get(grouped, :observation, [])

    if goals == [] and observations == [] do
      nil
    else
      lines = ["## Summary\n"]

      lines =
        if goals != [] do
          goal_lines =
            Enum.map(goals, fn g ->
              if g.description, do: "- **#{g.title}**: #{g.description}", else: "- **#{g.title}**"
            end)

          lines ++ goal_lines
        else
          lines
        end

      lines =
        if observations != [] do
          obs_lines =
            Enum.map(observations, fn o ->
              if o.description, do: "- #{o.title}: #{o.description}", else: "- #{o.title}"
            end)

          lines ++ ["\n### Observations\n"] ++ obs_lines
        else
          lines
        end

      Enum.join(lines, "\n") <> "\n"
    end
  end

  defp decisions_section(grouped, edges) do
    decisions = Map.get(grouped, :decision, [])

    if decisions == [] do
      nil
    else
      edges_by_from = Enum.group_by(edges, & &1.from_node_id)
      all_nodes_by_id = build_node_index(grouped)

      decision_blocks =
        Enum.map(decisions, fn decision ->
          outgoing = Map.get(edges_by_from, decision.id, [])

          option_lines =
            outgoing
            |> Enum.filter(fn e -> e.edge_type in [:chosen, :rejected, :leads_to] end)
            |> Enum.map(fn edge ->
              option_node = Map.get(all_nodes_by_id, edge.to_node_id)
              option_title = if option_node, do: option_node.title, else: edge.to_node_id

              case edge.edge_type do
                :chosen -> "  - [x] #{option_title}"
                :rejected -> "  - [ ] #{option_title}"
                :leads_to -> "  - #{option_title}"
              end
            end)

          header = "### #{decision.title}"
          desc = if decision.description, do: "\n#{decision.description}\n", else: ""
          options = if option_lines != [], do: "\n" <> Enum.join(option_lines, "\n"), else: ""
          header <> desc <> options
        end)

      "## Key Decisions\n\n" <> Enum.join(decision_blocks, "\n\n") <> "\n"
    end
  end

  defp implementation_section(grouped) do
    actions = Map.get(grouped, :action, [])

    if actions == [] do
      nil
    else
      lines =
        Enum.map(actions, fn a ->
          if a.description, do: "- **#{a.title}**: #{a.description}", else: "- #{a.title}"
        end)

      "## Implementation\n\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp results_section(grouped) do
    outcomes = Map.get(grouped, :outcome, [])

    if outcomes == [] do
      nil
    else
      lines =
        Enum.map(outcomes, fn o ->
          if o.description, do: "- **#{o.title}**: #{o.description}", else: "- #{o.title}"
        end)

      "## Results\n\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp prior_attempts_section(nodes) do
    prior =
      Enum.filter(nodes, fn n -> n.status in [:superseded, :abandoned] end)

    if prior == [] do
      nil
    else
      lines =
        Enum.map(prior, fn n ->
          status_label = if n.status == :superseded, do: "superseded", else: "abandoned"
          "- ~~#{n.title}~~ (#{status_label})"
        end)

      "## Prior Attempts\n\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp test_plan_section do
    """
    ## Test Plan

    - [ ] Unit tests pass
    - [ ] Integration tests pass
    - [ ] Manual verification complete
    - [ ] Edge cases covered
    """
  end

  defp build_node_index(grouped) do
    grouped
    |> Map.values()
    |> List.flatten()
    |> Map.new(fn n -> {n.id, n} end)
  end
end
