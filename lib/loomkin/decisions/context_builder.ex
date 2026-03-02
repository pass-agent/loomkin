defmodule Loomkin.Decisions.ContextBuilder do
  @moduledoc "Builds structured decision context for system prompt injection."

  alias Loomkin.Decisions.{Graph, Narrative}

  @default_max_tokens 1024

  def build(session_id, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    max_chars = max_tokens * 4

    sections = [
      build_goals_section(),
      build_decisions_section(),
      build_session_section(session_id)
    ]

    result = Enum.join(sections, "\n\n")
    {:ok, truncate(result, max_chars)}
  end

  defp build_goals_section do
    goals = Graph.active_goals()

    if goals == [] do
      "## Active Goals\nNone."
    else
      items =
        Enum.map_join(goals, "\n", fn g ->
          conf = if g.confidence, do: " (confidence: #{g.confidence}%)", else: ""
          "- #{g.title}#{conf}"
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
          "- [#{d.node_type}] #{d.title}"
        end)

      "## Recent Decisions\n#{items}"
    end
  end

  defp build_session_section(session_id) do
    entries = Narrative.for_session(session_id)

    if entries == [] do
      "## Session Context\nNo decisions recorded in this session."
    else
      timeline = Narrative.format_timeline(entries)
      "## Session Context\n#{timeline}"
    end
  end

  defp truncate(text, max_chars) when byte_size(text) <= max_chars, do: text

  defp truncate(text, max_chars) do
    String.slice(text, 0, max_chars - 15) <> "\n[truncated...]"
  end
end
