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
        "group flex-col px-2 py-1.5 rounded-md cursor-pointer transition-colors duration-100",
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
        </div>

        <%!-- Timestamp --%>
        <span class="flex-shrink-0 text-[10px] tabular-nums text-zinc-500 leading-5">
          {format_timestamp(@event.timestamp)}
        </span>
      </summary>

      <%!-- Expanded content --%>
      <div
        class="mt-1 ml-5 text-xs text-zinc-300 whitespace-pre-wrap rounded px-2 py-1.5"
        style={"background: #{@config.accent_bg};"}
      >
        {@event.content}
      </div>
    </details>
    """
  end

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
