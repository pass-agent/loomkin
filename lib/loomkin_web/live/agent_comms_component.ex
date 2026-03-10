defmodule LoomkinWeb.AgentCommsComponent do
  @moduledoc """
  Functional component that renders the inter-agent communication feed.

  Renders the "social layer" of mission control — messages, discoveries,
  decisions, task lifecycle, escalations, and other inter-agent comms
  as compact, color-coded rows.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias LoomkinWeb.AgentColors

  @type_config %{
    message: %{
      icon: "✉",
      accent_border: "rgba(52, 211, 153, 0.30)",
      accent_text: "#6ee7b7",
      accent_bg: "rgba(52, 211, 153, 0.08)"
    },
    discovery: %{
      icon: "⭐",
      accent_border: "rgba(251, 191, 36, 0.30)",
      accent_text: "#fcd34d",
      accent_bg: "rgba(251, 191, 36, 0.08)"
    },
    decision: %{
      icon: "🧠",
      accent_border: "rgba(167, 139, 250, 0.35)",
      accent_text: "#c4b5fd",
      accent_bg: "rgba(167, 139, 250, 0.10)"
    },
    task_created: %{
      icon: "✚",
      accent_border: "rgba(34, 211, 238, 0.30)",
      accent_text: "#67e8f9",
      accent_bg: "rgba(34, 211, 238, 0.08)"
    },
    task_assigned: %{
      icon: "➤",
      accent_border: "rgba(96, 165, 250, 0.30)",
      accent_text: "#93bbfd",
      accent_bg: "rgba(96, 165, 250, 0.08)"
    },
    task_complete: %{
      icon: "✔",
      accent_border: "rgba(74, 222, 128, 0.30)",
      accent_text: "#86efac",
      accent_bg: "rgba(74, 222, 128, 0.08)"
    },
    error: %{
      icon: "⚠",
      accent_border: "rgba(248, 113, 113, 0.35)",
      accent_text: "#fca5a5",
      accent_bg: "rgba(248, 113, 113, 0.10)"
    },
    agent_spawn: %{
      icon: "✳",
      accent_border: "rgba(45, 212, 191, 0.25)",
      accent_text: "#5eead4",
      accent_bg: "rgba(45, 212, 191, 0.06)"
    },
    question: %{
      icon: "❔",
      accent_border: "rgba(56, 189, 248, 0.35)",
      accent_text: "#7dd3fc",
      accent_bg: "rgba(56, 189, 248, 0.10)"
    },
    answer: %{
      icon: "❕",
      accent_border: "rgba(56, 189, 248, 0.25)",
      accent_text: "#7dd3fc",
      accent_bg: "rgba(56, 189, 248, 0.08)"
    },
    tasks_unblocked: %{
      icon: "🔓",
      accent_border: "rgba(74, 222, 128, 0.25)",
      accent_text: "#86efac",
      accent_bg: "rgba(74, 222, 128, 0.06)"
    },
    role_changed: %{
      icon: "🔄",
      accent_border: "rgba(129, 140, 248, 0.25)",
      accent_text: "#a5b4fc",
      accent_bg: "rgba(129, 140, 248, 0.08)"
    },
    escalation: %{
      icon: "📈",
      accent_border: "rgba(251, 146, 60, 0.25)",
      accent_text: "#fdba74",
      accent_bg: "rgba(251, 146, 60, 0.08)"
    },
    collab_event: %{
      icon: "🤝",
      accent_border: "rgba(167, 139, 250, 0.25)",
      accent_text: "#c4b5fd",
      accent_bg: "rgba(167, 139, 250, 0.08)"
    },
    channel_message: %{
      icon: "💬",
      accent_border: "rgba(34, 211, 238, 0.25)",
      accent_text: "#67e8f9",
      accent_bg: "rgba(34, 211, 238, 0.08)"
    },
    peer_message: %{
      icon: "💬",
      accent_border: "rgba(96, 165, 250, 0.30)",
      accent_text: "#93bbfd",
      accent_bg: "rgba(96, 165, 250, 0.08)"
    },
    agent_crashed: %{
      icon: "⚠",
      accent_border: "rgba(239, 68, 68, 0.40)",
      accent_text: "#fca5a5",
      accent_bg: "rgba(239, 68, 68, 0.12)"
    },
    agent_recovered: %{
      icon: "🔄",
      accent_border: "rgba(251, 191, 36, 0.35)",
      accent_text: "#fcd34d",
      accent_bg: "rgba(251, 191, 36, 0.10)"
    },
    agent_permanently_failed: %{
      icon: "💀",
      accent_border: "rgba(185, 28, 28, 0.40)",
      accent_text: "#f87171",
      accent_bg: "rgba(185, 28, 28, 0.12)"
    },
    human_broadcast: %{
      icon: "📢",
      accent_border: "rgba(251, 191, 36, 0.35)",
      accent_text: "#fcd34d",
      accent_bg: "rgba(251, 191, 36, 0.10)"
    },
    human_reply: %{
      icon: "💬",
      accent_border: "rgba(52, 211, 153, 0.30)",
      accent_text: "#6ee7b7",
      accent_bg: "rgba(52, 211, 153, 0.08)"
    },
    agent_paused: %{
      icon: "⏸",
      accent_border: "rgba(96, 165, 250, 0.30)",
      accent_text: "#93bbfd",
      accent_bg: "rgba(96, 165, 250, 0.08)"
    },
    permission_requested: %{
      icon: "🔒",
      accent_border: "rgba(251, 146, 60, 0.35)",
      accent_text: "#fdba74",
      accent_bg: "rgba(251, 146, 60, 0.10)"
    },
    agent_force_paused: %{
      icon: "⏹",
      accent_border: "rgba(239, 68, 68, 0.30)",
      accent_text: "#fca5a5",
      accent_bg: "rgba(239, 68, 68, 0.08)"
    },
    approval_gate_requested: %{
      icon: "🔐",
      accent_border: "rgba(124, 58, 237, 0.40)",
      accent_text: "#a78bfa",
      accent_bg: "rgba(124, 58, 237, 0.12)"
    },
    approval_gate_resolved: %{
      icon: "✔",
      accent_border: "rgba(124, 58, 237, 0.30)",
      accent_text: "#8b5cf6",
      accent_bg: "rgba(124, 58, 237, 0.08)"
    },
    spawn_gate_opened: %{
      icon: "🔮",
      accent_border: "rgba(124, 58, 237, 0.40)",
      accent_text: "#a78bfa",
      accent_bg: "rgba(124, 58, 237, 0.12)"
    },
    spawn_gate_resolved: %{
      icon: "✔",
      accent_border: "rgba(124, 58, 237, 0.30)",
      accent_text: "#8b5cf6",
      accent_bg: "rgba(124, 58, 237, 0.08)"
    },
    awaiting_synthesis_started: %{
      icon: "🔬",
      accent_border: "rgba(99, 102, 241, 0.40)",
      accent_text: "#818cf8",
      accent_bg: "rgba(99, 102, 241, 0.12)"
    },
    awaiting_synthesis_complete: %{
      icon: "✔",
      accent_border: "rgba(99, 102, 241, 0.30)",
      accent_text: "#6366f1",
      accent_bg: "rgba(99, 102, 241, 0.08)"
    },
    rebalance_nudge: %{
      icon: "⏰",
      accent_border: "rgba(251, 191, 36, 0.35)",
      accent_text: "#fbbf24",
      accent_bg: "rgba(251, 191, 36, 0.10)"
    },
    rebalance_escalation: %{
      icon: "⚠",
      accent_border: "rgba(245, 158, 11, 0.40)",
      accent_text: "#f59e0b",
      accent_bg: "rgba(245, 158, 11, 0.12)"
    },
    conflict: %{
      icon: "⚔",
      accent_border: "rgba(239, 68, 68, 0.40)",
      accent_text: "#f87171",
      accent_bg: "rgba(239, 68, 68, 0.12)"
    },
    vote_response: %{
      icon: "🗳",
      accent_border: "rgba(129, 140, 248, 0.35)",
      accent_text: "#a5b4fc",
      accent_bg: "rgba(129, 140, 248, 0.10)"
    },
    debate_response: %{
      icon: "💭",
      accent_border: "rgba(244, 114, 182, 0.35)",
      accent_text: "#f9a8d4",
      accent_bg: "rgba(244, 114, 182, 0.10)"
    }
  }

  @default_config %{
    icon: "●",
    accent_border: "rgba(113, 113, 122, 0.20)",
    accent_text: "#a1a1aa",
    accent_bg: "rgba(113, 113, 122, 0.06)"
  }

  attr :stream, :any, required: true
  attr :event_count, :integer, default: 0
  attr :id, :string, default: "agent-comms"
  attr :root_team_id, :string, default: nil

  def comms_feed(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col h-full relative">
      <%!-- Section header --%>
      <div class="px-3 py-2 flex items-center gap-2">
        <span class="text-[10px] font-semibold text-muted uppercase tracking-widest">
          Kin Comms
        </span>
        <span class="badge text-[10px] tabular-nums">{@event_count}</span>
      </div>

      <%!-- Scrollable feed --%>
      <div
        id="comms-feed-scroll"
        phx-hook="CommsFeedScroll"
        phx-update="stream"
        role="log"
        aria-label="Agent communications feed"
        class="flex-1 overflow-y-auto px-2 pb-2 space-y-0.5"
      >
        <div
          id="comms-empty-state"
          class="hidden only:flex items-center justify-center py-12 text-muted text-xs"
        >
          No inter-agent communication yet
        </div>

        <div :for={{dom_id, event} <- @stream} id={dom_id}>
          <.comms_row event={event} root_team_id={@root_team_id} />
        </div>
      </div>

      <%!-- New messages indicator --%>
      <div
        data-new-messages
        class="hidden absolute bottom-2 left-1/2 -translate-x-1/2 px-3 py-1 rounded-full bg-indigo-600/90 text-white text-[10px] font-medium cursor-pointer backdrop-blur-sm z-10"
        phx-click={JS.dispatch("scroll-to-bottom", to: "#comms-feed-scroll")}
      >
      </div>
    </div>
    """
  end

  attr :event, :map, required: true
  attr :root_team_id, :string, default: nil

  defp comms_row(assigns) do
    config = type_config(assigns.event.type)
    agent_color = AgentColors.agent_color(assigns.event.agent)
    assigns = assigns |> assign(:config, config) |> assign(:agent_color, agent_color)

    ~H"""
    <details
      id={"comms-event-#{@event.id}"}
      class={[
        "group flex-col px-2 py-1.5 rounded-md cursor-pointer transition-colors duration-100 animate-fade-in",
        "border-l-2"
      ]}
      style={"border-left-color: #{@config.accent_border};"}
    >
      <summary class="flex items-start gap-2 list-none [&::-webkit-details-marker]:hidden">
        <%!-- Icon --%>
        <span
          class="flex-shrink-0 text-xs leading-5 select-none"
          style={"color: #{@config.accent_text};"}
        >
          {@config.icon}
        </span>

        <%!-- Body --%>
        <div class="flex-1 min-w-0 flex items-baseline gap-1.5">
          <button
            class="text-xs font-semibold hover:underline flex-shrink-0"
            style={"color: #{@agent_color};"}
            phx-click="focus_card_agent"
            phx-value-agent={@event.agent}
            type="button"
          >
            {@event.agent}
          </button>
          <span
            :if={@event.metadata[:team_id] && @event.metadata[:team_id] != @root_team_id}
            class="flex-shrink-0 text-[9px] font-mono px-1.5 py-0.5 rounded-full bg-zinc-800 text-zinc-400 border border-zinc-700/50"
          >
            {short_team_label(@event.metadata[:team_id])}
          </span>
          <span class="text-xs text-zinc-400 leading-5 truncate">
            {@event.content}
          </span>
          <span
            :if={@event.type == :discovery && @event.metadata[:relevance]}
            class="flex-shrink-0 text-[9px] font-mono px-1.5 py-0.5 rounded-full bg-emerald-900/40 text-emerald-400 border border-emerald-800/50"
            data-testid="relevance-badge"
            title={relevance_badge_title(@event.metadata[:relevance])}
          >
            {length(@event.metadata[:relevance][:recipients] || [])} recipients
          </span>
        </div>

        <%!-- Timestamp --%>
        <span class="flex-shrink-0 text-[10px] tabular-nums text-zinc-500 leading-5">
          {format_timestamp(@event.timestamp)}
        </span>
      </summary>

      <%!-- Expanded content --%>
      <div
        class="mt-1 ml-5 text-xs text-zinc-300 rounded px-2 py-1.5"
        style={"background: #{@config.accent_bg};"}
      >
        <.assignment_reasoning
          :if={@event.type == :task_assigned && @event.metadata[:task_type]}
          metadata={@event.metadata}
        />
        <.relevance_details
          :if={@event.type == :discovery && @event.metadata[:relevance]}
          metadata={@event.metadata}
          content={@event.content}
        />
        <span
          :if={
            (@event.type != :task_assigned || !@event.metadata[:task_type]) &&
              (@event.type != :discovery || !@event.metadata[:relevance])
          }
          class="whitespace-pre-wrap"
        >
          {@event.content}
        </span>
      </div>
    </details>
    """
  end

  attr :metadata, :map, required: true

  defp assignment_reasoning(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="flex items-center gap-2">
        <span class="text-zinc-500">Task type:</span>
        <span class="font-mono text-blue-400">{@metadata[:task_type]}</span>
      </div>
      <div :if={@metadata[:chosen_score]} class="flex items-center gap-2">
        <span class="text-zinc-500">Capability score:</span>
        <span class="font-mono text-emerald-400">{@metadata[:chosen_score]}</span>
        <span :if={@metadata[:chosen_stats]} class="text-zinc-500">
          ({@metadata[:chosen_stats].successes}/{@metadata[:chosen_stats].successes +
            @metadata[:chosen_stats].failures} success)
        </span>
      </div>
      <div :if={@metadata[:reason]} class="flex items-center gap-2">
        <span class="text-zinc-500">Reason:</span>
        <span class="text-zinc-300">{@metadata[:reason]}</span>
      </div>
      <div :if={@metadata[:alternatives] != []} class="mt-1">
        <span class="text-zinc-500">Alternatives:</span>
        <div :for={alt <- @metadata[:alternatives]} class="ml-2 flex items-center gap-2 text-zinc-400">
          <span class="font-medium">{alt.agent}</span>
          <span class="font-mono text-zinc-500">score: {alt.score}</span>
          <span :if={alt[:stats]} class="text-zinc-600">
            ({alt.stats.successes}/{alt.stats.successes + alt.stats.failures})
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :metadata, :map, required: true
  attr :content, :string, required: true

  defp relevance_details(assigns) do
    relevance = assigns.metadata[:relevance] || %{}
    recipients = relevance[:recipients] || []
    skipped = relevance[:skipped] || []

    assigns =
      assigns
      |> assign(:recipients, recipients)
      |> assign(:skipped, skipped)

    ~H"""
    <div class="space-y-1.5" data-testid="relevance-details">
      <span class="whitespace-pre-wrap">{@content}</span>
      <div :if={@recipients != []} class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 mt-1">
        <span class="text-zinc-500">Sent to:</span>
        <span :for={{agent, score} <- @recipients} class="inline-flex items-center gap-0.5">
          <span class="font-medium text-emerald-400">{agent}</span>
          <span class="font-mono text-zinc-500">({format_score(score)})</span>
        </span>
      </div>
      <div :if={@skipped != []} class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5">
        <span class="text-zinc-500">Filtered:</span>
        <span :for={{agent, score} <- @skipped} class="inline-flex items-center gap-0.5">
          <span class="font-medium text-zinc-500">{agent}</span>
          <span class="font-mono text-zinc-600">({format_score(score)})</span>
        </span>
      </div>
    </div>
    """
  end

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 2)
  defp format_score(score), do: to_string(score)

  defp relevance_badge_title(%{recipients: recipients, skipped: skipped}) do
    sent =
      recipients
      |> Enum.map(fn {agent, score} -> "#{agent} (#{format_score(score)})" end)
      |> Enum.join(", ")

    filtered =
      skipped
      |> Enum.map(fn {agent, score} -> "#{agent} (#{format_score(score)})" end)
      |> Enum.join(", ")

    parts = ["Sent to: #{sent}"]
    parts = if filtered != "", do: parts ++ ["Filtered: #{filtered}"], else: parts
    Enum.join(parts, " | ")
  end

  defp relevance_badge_title(_), do: ""

  defp type_config(type), do: Map.get(@type_config, type, @default_config)

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_timestamp(_), do: ""

  defp short_team_label(team_id) when is_binary(team_id) do
    if String.length(team_id) > 8 do
      "sub-" <> String.slice(team_id, 0, 4)
    else
      team_id
    end
  end

  defp short_team_label(_), do: ""
end
