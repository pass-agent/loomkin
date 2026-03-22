defmodule Loomkin.Decisions.ContextBuilder do
  @moduledoc "Builds structured decision context for system prompt injection."

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.Narrative

  @default_max_tokens 1024
  @section_max_chars 1024

  def build(session_id, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    cross_session = Keyword.get(opts, :cross_session, false)
    max_chars = max_tokens * 4

    sections = [
      build_goals_section(session_id, cross_session),
      build_decisions_section(),
      build_prior_attempts_section(),
      build_session_section(session_id)
    ]

    result = sections |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    {:ok, truncate(result, max_chars)}
  end

  defp build_goals_section(session_id, cross_session) do
    goals =
      if cross_session do
        Graph.list_nodes(node_type: :goal, status: :active)
      else
        Graph.list_nodes(node_type: :goal, status: :active, session_id: session_id)
      end

    if goals == [] do
      "## Active Goals\nNone."
    else
      items =
        Enum.map_join(goals, "\n", fn g ->
          format_node_line(g)
        end)

      "## Active Goals\n#{items}"
    end
  end

  defp build_decisions_section do
    decisions = Graph.recent_decisions(5)

    if decisions == [] do
      "## Recent Decisions\nNone."
    else
      items =
        Enum.map_join(decisions, "\n", fn d ->
          "- [#{d.node_type}] #{d.title}#{format_keeper_ref(d)}"
        end)

      "## Recent Decisions\n#{items}"
    end
  end

  defp build_prior_attempts_section do
    revisits = Graph.list_nodes(node_type: :revisit, status: :active)
    abandoned = Graph.list_nodes(status: :abandoned)
    superseded = Graph.list_nodes(status: :superseded)

    items =
      Enum.map(revisits, fn n ->
        confidence = if n.confidence, do: " (confidence: #{n.confidence})", else: ""
        keeper = format_keeper_ref(n)
        "- [REVISIT] #{n.title}#{confidence} — needs re-evaluation#{keeper}"
      end) ++
        Enum.map(abandoned, fn n ->
          desc = if n.description, do: " — #{n.description}", else: ""
          keeper = format_keeper_ref(n)
          "- [ABANDONED] #{n.title}#{desc}#{keeper}"
        end) ++
        Enum.map(superseded, fn n ->
          keeper = format_keeper_ref(n)
          "- [SUPERSEDED] #{n.title} → replaced#{keeper}"
        end)

    if items == [], do: "", else: "## Prior Attempts & Lessons\n" <> Enum.join(items, "\n")
  end

  defp format_node_line(node) do
    base = "- #{node.title}"
    base = if node.confidence, do: "#{base} (confidence: #{node.confidence}%)", else: base
    base <> format_keeper_ref(node)
  end

  defp format_keeper_ref(node) do
    case node.metadata do
      %{"keeper_id" => id} when is_binary(id) -> " → Deep context available in keeper #{id}"
      _ -> ""
    end
  end

  defp build_session_section(session_id) do
    entries = Narrative.for_session(session_id)

    if entries == [] do
      "## Session Context\nNo decisions recorded in this session."
    else
      timeline = Narrative.format_timeline(entries)
      "## Session Context\n#{truncate(timeline, @section_max_chars)}"
    end
  end

  defp truncate(text, max_chars) when byte_size(text) <= max_chars, do: text

  defp truncate(text, max_chars) do
    String.slice(text, 0, max_chars - 15) <> "\n[truncated...]"
  end
end
