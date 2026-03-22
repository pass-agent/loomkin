defmodule LoomkinWeb.TeamActivityComponent do
  @moduledoc """
  Primary activity feed for Mission Control.

  Renders a rich, full-width center panel of team events with distinct card
  types for tool calls, inter-agent messages, task lifecycle, discoveries,
  agent spawns, errors, streaming, context offloads, and Q&A.

  Each event type has a unique visual signature: icon prefix, left border
  color, badge color, and optional background tint. High-signal fields
  (actor, action, target, outcome) are always visible in the card header;
  low-signal metadata (raw results, stack traces, full text) is collapsed
  behind expand toggles.

  Events are buffered in the parent LiveView (workspace_live) and passed
  as assigns. This ensures events survive tab switches — the component
  can unmount and remount without losing history.
  """

  use LoomkinWeb, :live_component

  import LoomkinWeb.TimeHelpers, only: [relative_time: 1]

  @type_config %{
    tool_call: %{
      label: "tool",
      icon: "&#9881;",
      accent: "#818cf8",
      accent_bg: "rgba(129, 140, 248, 0.10)",
      accent_border: "rgba(129, 140, 248, 0.35)",
      accent_text: "#a5b4fc",
      dot_color: "#818cf8"
    },
    message: %{
      label: "message",
      icon: "&#9993;",
      accent: "#34d399",
      accent_bg: "rgba(52, 211, 153, 0.08)",
      accent_border: "rgba(52, 211, 153, 0.30)",
      accent_text: "#6ee7b7",
      dot_color: "#34d399"
    },
    decision: %{
      label: "decision",
      icon: "&#129504;",
      accent: "#a78bfa",
      accent_bg: "rgba(167, 139, 250, 0.10)",
      accent_border: "rgba(167, 139, 250, 0.35)",
      accent_text: "#c4b5fd",
      dot_color: "#a78bfa"
    },
    task_created: %{
      label: "created",
      icon: "&#10010;",
      accent: "#22d3ee",
      accent_bg: "rgba(34, 211, 238, 0.08)",
      accent_border: "rgba(34, 211, 238, 0.30)",
      accent_text: "#67e8f9",
      dot_color: "#22d3ee"
    },
    task_assigned: %{
      label: "assigned",
      icon: "&#10132;",
      accent: "#60a5fa",
      accent_bg: "rgba(96, 165, 250, 0.08)",
      accent_border: "rgba(96, 165, 250, 0.30)",
      accent_text: "#93bbfd",
      dot_color: "#60a5fa"
    },
    task_started: %{
      label: "started",
      icon: "&#9654;",
      accent: "#818cf8",
      accent_bg: "rgba(129, 140, 248, 0.08)",
      accent_border: "rgba(129, 140, 248, 0.30)",
      accent_text: "#a5b4fc",
      dot_color: "#818cf8"
    },
    task_complete: %{
      label: "done",
      icon: "&#10004;",
      accent: "#4ade80",
      accent_bg: "rgba(74, 222, 128, 0.08)",
      accent_border: "rgba(74, 222, 128, 0.30)",
      accent_text: "#86efac",
      dot_color: "#4ade80"
    },
    task_failed: %{
      label: "failed",
      icon: "&#10006;",
      accent: "#f87171",
      accent_bg: "rgba(248, 113, 113, 0.10)",
      accent_border: "rgba(248, 113, 113, 0.35)",
      accent_text: "#fca5a5",
      dot_color: "#f87171"
    },
    discovery: %{
      label: "discovery",
      icon: "&#11088;",
      accent: "#fbbf24",
      accent_bg: "rgba(251, 191, 36, 0.08)",
      accent_border: "rgba(251, 191, 36, 0.30)",
      accent_text: "#fcd34d",
      dot_color: "#fbbf24"
    },
    error: %{
      label: "error",
      icon: "&#9888;",
      accent: "#f87171",
      accent_bg: "rgba(248, 113, 113, 0.10)",
      accent_border: "rgba(248, 113, 113, 0.35)",
      accent_text: "#fca5a5",
      dot_color: "#f87171"
    },
    thinking: %{
      label: "thinking",
      icon: "&#8230;",
      accent: "#818cf8",
      accent_bg: "rgba(129, 140, 248, 0.06)",
      accent_border: "rgba(129, 140, 248, 0.20)",
      accent_text: "#a5b4fc",
      dot_color: "#818cf8"
    },
    streaming: %{
      label: "thinking",
      icon: "&#8230;",
      accent: "#818cf8",
      accent_bg: "rgba(129, 140, 248, 0.06)",
      accent_border: "rgba(129, 140, 248, 0.20)",
      accent_text: "#a5b4fc",
      dot_color: "#818cf8"
    },
    agent_spawn: %{
      label: "joined",
      icon: "&#10035;",
      accent: "#2dd4bf",
      accent_bg: "rgba(45, 212, 191, 0.06)",
      accent_border: "rgba(45, 212, 191, 0.25)",
      accent_text: "#5eead4",
      dot_color: "#2dd4bf"
    },
    context_offload: %{
      label: "offload",
      icon: "&#128230;",
      accent: "#f59e0b",
      accent_bg: "rgba(245, 158, 11, 0.08)",
      accent_border: "rgba(245, 158, 11, 0.25)",
      accent_text: "#fcd34d",
      dot_color: "#f59e0b"
    },
    question: %{
      label: "question",
      icon: "&#10068;",
      accent: "#38bdf8",
      accent_bg: "rgba(56, 189, 248, 0.10)",
      accent_border: "rgba(56, 189, 248, 0.35)",
      accent_text: "#7dd3fc",
      dot_color: "#38bdf8"
    },
    answer: %{
      label: "answer",
      icon: "&#10069;",
      accent: "#38bdf8",
      accent_bg: "rgba(56, 189, 248, 0.08)",
      accent_border: "rgba(56, 189, 248, 0.25)",
      accent_text: "#7dd3fc",
      dot_color: "#38bdf8"
    },
    channel_message: %{
      label: "channel",
      icon: "&#128172;",
      accent: "#22d3ee",
      accent_bg: "rgba(34, 211, 238, 0.08)",
      accent_border: "rgba(34, 211, 238, 0.25)",
      accent_text: "#67e8f9",
      dot_color: "#22d3ee"
    }
  }

  @max_events 200

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       all_events: [],
       known_agents: [],
       event_count: 0,
       focused_agent: nil,
       agent_filter: nil,
       type_filter: MapSet.new(),
       expanded_ids: MapSet.new()
     )
     |> stream(:filtered_events, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:team_id, assigns[:team_id])
      |> assign(:id, assigns[:id])
      |> assign(:known_agents, assigns[:known_agents] || socket.assigns.known_agents)

    # Accept focused_agent from parent (e.g. roster click) — auto-apply as agent filter
    socket =
      case assigns[:focused_agent] do
        nil -> socket
        agent -> assign(socket, focused_agent: agent, agent_filter: agent)
      end

    # Handle new events pushed from parent via send_update
    socket =
      case assigns[:new_event] do
        nil ->
          socket

        event ->
          all = socket.assigns.all_events ++ [event]
          all = if length(all) > @max_events, do: tl(all), else: all

          socket = assign(socket, all_events: all, event_count: length(all))

          if event_matches_filter?(event, socket.assigns) do
            stream_insert(socket, :filtered_events, event)
          else
            socket
          end
      end

    # Handle bulk event reset (e.g. initial history load)
    socket =
      case assigns[:reset_events] do
        nil ->
          socket

        events ->
          all = Enum.take(events, -@max_events)
          filtered = apply_filters(all, socket.assigns)

          socket
          |> assign(all_events: all, event_count: length(all))
          |> stream(:filtered_events, filtered, reset: true)
      end

    {:ok, socket}
  end

  # --- UI Event Handlers ---

  @impl true
  def handle_event("filter_agent", %{"agent" => ""}, socket) do
    socket =
      socket
      |> assign(agent_filter: nil, focused_agent: nil)
      |> refilter_stream()

    {:noreply, socket}
  end

  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    current = socket.assigns.agent_filter
    new_filter = if(current == agent, do: nil, else: agent)

    socket =
      socket
      |> assign(agent_filter: new_filter, focused_agent: nil)
      |> refilter_stream()

    {:noreply, socket}
  end

  @valid_event_types ~w(tool_call message task_created task_assigned task_complete discovery error thinking agent_spawn context_offload question channel_message)
  def handle_event("toggle_type", %{"type" => type_str}, socket)
      when type_str in @valid_event_types do
    type = String.to_existing_atom(type_str)
    filter = socket.assigns.type_filter

    new_filter =
      if MapSet.member?(filter, type),
        do: MapSet.delete(filter, type),
        else: MapSet.put(filter, type)

    socket =
      socket
      |> assign(type_filter: new_filter)
      |> refilter_stream()

    {:noreply, socket}
  end

  def handle_event("expand_event", %{"id" => id}, socket) do
    expanded_ids = socket.assigns.expanded_ids

    expanded_ids =
      if MapSet.member?(expanded_ids, id),
        do: MapSet.delete(expanded_ids, id),
        else: MapSet.put(expanded_ids, id)

    {:noreply, assign(socket, expanded_ids: expanded_ids)}
  end

  def handle_event("focus_agent", %{"agent" => agent}, socket) do
    send(self(), {:focus_agent, agent})
    {:noreply, socket}
  end

  def handle_event("inspect_file", %{"path" => path}, socket) do
    send(self(), {:inspector_file, path})
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-surface-0">
      <%!-- Filter Bar --%>
      <div class="glass-subtle flex flex-col border-b border-subtle">
        <%!-- Agent Filters --%>
        <div class="flex items-center gap-1.5 px-3 py-2 overflow-x-auto scrollbar-thin">
          <button
            phx-click="filter_agent"
            phx-value-agent=""
            phx-target={@myself}
            class="press-down flex-shrink-0"
            style={"display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 9999px; font-size: 0.75rem; font-weight: 500; transition: all 200ms; #{if @agent_filter == nil, do: "background: var(--brand-subtle); color: var(--text-brand); border: 1px solid var(--border-brand);", else: "background: var(--surface-2); color: var(--text-muted); border: 1px solid var(--border-subtle);"}"}
          >
            All
          </button>
          <button
            :for={agent <- @known_agents}
            phx-click="filter_agent"
            phx-value-agent={agent}
            phx-target={@myself}
            class="press-down flex-shrink-0"
            style={"display: inline-flex; align-items: center; gap: 5px; padding: 3px 10px; border-radius: 9999px; font-size: 0.75rem; font-weight: 500; transition: all 200ms; #{if @agent_filter == agent, do: "background: #{agent_color(agent)}18; color: #{agent_color(agent)}; border: 1px solid #{agent_color(agent)}40;", else: "background: var(--surface-2); color: var(--text-secondary); border: 1px solid var(--border-subtle);"}"}
          >
            <span
              class="flex-shrink-0"
              style={"width: 6px; height: 6px; border-radius: 9999px; background-color: #{agent_color(agent)};"}
            >
            </span>
            {agent}
          </button>
        </div>

        <%!-- Type Filters --%>
        <div class="flex items-center gap-1.5 px-3 py-1.5 overflow-x-auto scrollbar-thin border-t border-subtle">
          <button
            :for={{type, config} <- type_config_list()}
            phx-click="toggle_type"
            phx-value-type={type}
            phx-target={@myself}
            class="press-down flex-shrink-0"
            style={"display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; transition: all 200ms; #{if MapSet.size(@type_filter) > 0 && !MapSet.member?(@type_filter, type), do: "opacity: 0.3;"} color: #{config.accent_text}; background: transparent; border: none;"}
          >
            <span
              class="flex-shrink-0"
              style={"width: 6px; height: 6px; border-radius: 9999px; background-color: #{config.dot_color};"}
            >
            </span>
            {config.label}
          </button>
        </div>
      </div>

      <%!-- Event Feed --%>
      <div class="flex-1 overflow-auto" id={"activity-feed-#{@id}"} phx-hook="ScrollToBottom">
        <div class="activity-scroll-indicator" aria-hidden="true" />
        <div
          id={"activity-stream-#{@id}"}
          phx-update="stream"
          role="log"
          aria-label="Team activity"
          aria-live="polite"
          class="flex flex-col gap-1.5 p-2.5"
        >
          <div class="hidden only:flex items-center justify-center h-48">
            <div class="text-center space-y-3">
              <div class="text-muted text-3xl opacity-30">&#9673;</div>
              <p class="text-sm text-muted">No activity yet</p>
              <p class="text-xs text-muted opacity-60">
                Events will appear here as your kin works
              </p>
            </div>
          </div>

          <div
            :for={{dom_id, event} <- @streams.filtered_events}
            id={dom_id}
            class="activity-event-enter"
          >
            {render_event_card(assigns, event)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Card Renderers ---

  # Tool call: icon + agent + tool badge + file target in header; result collapsed
  defp render_event_card(assigns, %{type: :tool_call} = event) do
    config = @type_config.tool_call
    meta = Map.get(event, :metadata, %{})
    tool_name = meta[:tool_name] || extract_tool_name(event.content)
    file_path = meta[:file_path]
    command = meta[:command]
    result_preview = meta[:result] || meta[:result_preview]
    has_result = is_binary(result_preview) and result_preview != ""
    has_command = is_binary(command) and command != ""
    has_details = has_result or has_command
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    # For shell commands, show a truncated preview inline
    command_preview =
      if has_command do
        if String.length(command) > 60, do: String.slice(command, 0, 60) <> "...", else: command
      end

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:tool_name, tool_name)
      |> assign(:file_path, file_path)
      |> assign(:command, command)
      |> assign(:command_preview, command_preview)
      |> assign(:result_preview, result_preview)
      |> assign(:has_result, has_result)
      |> assign(:has_command, has_command)
      |> assign(:has_details, has_details)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          {Phoenix.HTML.raw(tool_icon(@tool_name))} {@tool_name}
        </span>
        <button
          :if={is_binary(@file_path)}
          phx-click="inspect_file"
          phx-value-path={@file_path}
          phx-target={@myself}
          style={"font-size: 0.6875rem; font-family: var(--font-mono); color: #{@config.accent_text}; opacity: 0.7; transition: opacity 200ms;"}
          class="truncate min-w-0"
        >
          {Path.basename(@file_path)}
        </button>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Shell command preview --%>
      <div :if={@has_command} class="px-3 pb-1.5">
        <code class="text-[11px] font-mono text-emerald-400/90 bg-emerald-500/5 border border-emerald-500/10 rounded px-1.5 py-0.5 inline-block max-w-full truncate">
          $ {@command_preview}
        </code>
      </div>
      <%!-- Expandable details: full command + result --%>
      <div :if={@has_details} class="px-3 pb-2">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-11 text-muted transition-colors duration-200"
        >
          &#9656; {expand_label(@has_command, @has_result, @command, @result_preview)}
        </button>
        <div :if={@expanded} class="animate-fade-in-up space-y-1.5">
          <div :if={@has_command}>
            <p class="text-[10px] text-muted uppercase tracking-wider mb-0.5">Command</p>
            <pre class="overflow-auto text-11 font-mono text-emerald-300 whitespace-pre-wrap break-words bg-zinc-950 border border-emerald-500/10 rounded-md px-3 py-2 max-h-32">$ {@command}</pre>
          </div>
          <div :if={@has_result}>
            <p class="text-[10px] text-muted uppercase tracking-wider mb-0.5">Output</p>
            <pre class="overflow-auto text-11 font-mono text-secondary whitespace-pre-wrap break-words bg-surface-0 border border-subtle rounded-md px-3 py-2 max-h-64">{@result_preview}</pre>
          </div>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="mt-0.5 text-11 text-muted transition-colors duration-200"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
      <%!-- Fallback: show content if no details --%>
      <div :if={!@has_details && String.length(@event.content) > 0} class="px-3 pb-2">
        <p class="text-xs text-secondary break-words">
          {@event.content}
        </p>
      </div>
    </div>
    """
  end

  # Message: agent -> recipient, content truncated with expand
  defp render_event_card(assigns, %{type: :message} = event) do
    config = @type_config.message
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent
    to = meta[:to]
    display_to = if to, do: to, else: "Kin"
    content = event.content || ""
    long_content = String.length(content) > 280
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:from, from)
      |> assign(:display_to, display_to)
      |> assign(:content_text, content)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@from)}; transition: opacity 200ms;"}
        >
          {@from}
        </button>
        <span class="text-11 text-muted">&#8594;</span>
        <span
          style={"font-size: 0.75rem; font-weight: 500; color: #{@config.accent_text};"}
          class="truncate"
        >
          {@display_to}
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class={[
          "text-13 text-primary leading-normal whitespace-pre-wrap break-words",
          if(@long_content && !@expanded, do: "line-clamp-3")
        ]}>
          {@content_text}
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.7; transition: opacity 200ms;"}
        >
          show more
        </button>
        <button
          :if={@long_content && @expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1 text-11 text-muted transition-opacity duration-200"
        >
          show less
        </button>
      </div>
    </div>
    """
  end

  # Task lifecycle: distinct icons per state, title + owner in header
  defp render_event_card(assigns, %{type: type} = event)
       when type in [:task_created, :task_assigned, :task_started, :task_complete, :task_failed] do
    meta = Map.get(event, :metadata, %{})
    config = Map.get(@type_config, type, fallback_config())
    title = meta[:title]
    owner = meta[:owner]
    result = meta[:result]
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:title, title)
      |> assign(:owner, owner)
      |> assign(:result, result)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          {Phoenix.HTML.raw(@config.icon)} {@config.label}
        </span>
        <span
          :if={@title}
          class="truncate min-w-0 text-xs font-medium text-primary"
        >
          {@title}
        </span>
        <span
          :if={@owner}
          class="flex-shrink-0 text-11 text-muted"
        >
          &#8594; <span class="text-secondary">{@owner}</span>
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Show content only when there is no title (fallback) --%>
      <div :if={!@title && @event.content != ""} class="px-3 pb-2">
        <p class="text-xs text-secondary break-words">
          {@event.content}
        </p>
      </div>
      <%!-- Collapsible result for completed tasks --%>
      <div :if={@result && @event.type == :task_complete} class="px-3 pb-2">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-11 text-muted transition-colors duration-200"
        >
          &#9656; Show result
        </button>
        <div :if={@expanded} class="animate-fade-in-up">
          <pre class="overflow-auto text-11 font-mono text-secondary whitespace-pre-wrap break-words bg-surface-0 border border-subtle rounded-md px-3 py-2 max-h-48">{@result}</pre>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="mt-1 text-11 text-muted transition-colors duration-200"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Discovery: highlighted background, star icon, content always visible
  defp render_event_card(assigns, %{type: :discovery} = event) do
    config = @type_config.discovery
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    content = event.content || ""
    long_content = String.length(content) > 200

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:content_text, content)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid #{@config.accent_border}; border-left: 2px solid #{@config.accent}; border-radius: 0.5rem; box-shadow: 0 0 16px rgba(251, 191, 36, 0.06);"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span class="badge-warning flex-shrink-0 px-2 py-px text-11">
          &#11088; discovery
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p
          class={if @long_content && !@expanded, do: "line-clamp-2"}
          style={"font-size: 0.8125rem; color: #{@config.accent_text}; line-height: 1.5; white-space: pre-wrap; word-break: break-word;"}
        >
          {@content_text}
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.6; transition: opacity 200ms;"}
        >
          show more
        </button>
        <button
          :if={@long_content && @expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.6; transition: opacity 200ms;"}
        >
          show less
        </button>
      </div>
    </div>
    """
  end

  # Agent spawn: centered banner style, compact
  defp render_event_card(assigns, %{type: :agent_spawn} = event) do
    config = @type_config.agent_spawn
    meta = Map.get(event, :metadata, %{})
    role = meta[:role]
    model = meta[:model]
    agent_name = meta[:agent_name] || event.agent

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:agent_name, agent_name)
      |> assign(:role, role)
      |> assign(:model, model)

    ~H"""
    <div
      class="overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid #{@config.accent_border}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center justify-center gap-2 px-3 py-1.5 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@agent_name)};"}
        >
        </span>
        <span style={"font-size: 0.75rem; font-weight: 500; color: #{@config.accent_text};"}>
          &#10035; {@agent_name} joined
        </span>
        <span :if={@role} class="text-11 text-muted">
          as <span class="text-secondary">{@role}</span>
        </span>
        <span
          :if={@model}
          class="ml-auto text-11 font-mono text-muted"
        >
          {@model}
        </span>
        <span
          :if={!@model}
          class="ml-auto text-11 font-mono text-muted"
        >
          {relative_time(@event.timestamp)}
        </span>
      </div>
    </div>
    """
  end

  # Error: red tint, warning icon, error message in header, details collapsible
  defp render_event_card(assigns, %{type: :error} = event) do
    config = @type_config.error
    meta = Map.get(event, :metadata, %{})
    details = meta[:details]
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    content = event.content || ""
    # Show brief error inline in header if short enough
    brief_error = String.length(content) <= 120

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:details, details)
      |> assign(:expanded, expanded)
      |> assign(:brief_error, brief_error)
      |> assign(:content_text, content)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid #{@config.accent_border}; border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span class="badge-danger flex-shrink-0 px-2 py-px text-11">
          &#9888; error
        </span>
        <span
          :if={@brief_error && @content_text != ""}
          class="truncate min-w-0"
          style={"font-size: 0.75rem; color: #{@config.accent_text}; opacity: 0.8;"}
        >
          {@content_text}
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Full error content if too long for header --%>
      <div :if={!@brief_error} class="px-3 pb-2">
        <p style={"font-size: 0.75rem; color: #{@config.accent_text}; opacity: 0.8; word-break: break-word;"}>
          {@content_text}
        </p>
      </div>
      <%!-- Collapsible details (stack trace etc.) --%>
      <div :if={@details} class="px-3 pb-2">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-11 text-muted transition-colors duration-200"
        >
          &#9656; Show details
        </button>
        <div :if={@expanded} class="animate-fade-in-up">
          <pre
            class="overflow-auto"
            style={"font-size: 0.6875rem; font-family: var(--font-mono); color: #{@config.accent_text}; opacity: 0.7; white-space: pre-wrap; word-break: break-word; background: var(--surface-0); border: 1px solid var(--border-subtle); border-radius: 0.375rem; padding: 0.5rem 0.75rem; max-height: 12rem;"}
          >{@details}</pre>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="mt-1 text-11 text-muted transition-colors duration-200"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Thinking/Streaming: subtle, with animated cursor for live streams
  defp render_event_card(assigns, %{type: type} = event) when type in [:thinking, :streaming] do
    config = @type_config[type]
    meta = Map.get(event, :metadata, %{})
    streaming_content = meta[:content]
    is_live = type == :streaming
    content = streaming_content || event.content || ""
    long_content = String.length(content) > 120
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:content_text, content)
      |> assign(:is_live, is_live)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class={"overflow-hidden #{if @is_live, do: "streaming-card"}"}
      style={"background: #{@config.accent_bg}; border: 1px solid #{@config.accent_border}; border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)}; #{if @is_live, do: "box-shadow: 0 0 6px #{agent_color(@event.agent)};"}"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; opacity: 0.7; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.6;"}>
          thinking
          <span :if={@is_live} class="inline-flex gap-0.5 ml-0.5 align-middle">
            <span
              class="thinking-dot inline-block rounded-full"
              style={"width: 3px; height: 3px; background-color: #{@config.accent_text};"}
            >
            </span>
            <span
              class="thinking-dot inline-block rounded-full"
              style={"width: 3px; height: 3px; background-color: #{@config.accent_text};"}
            >
            </span>
            <span
              class="thinking-dot inline-block rounded-full"
              style={"width: 3px; height: 3px; background-color: #{@config.accent_text};"}
            >
            </span>
          </span>
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div :if={@content_text != ""} class="px-3 pb-2">
        <p class={[
          "text-xs text-muted leading-normal whitespace-pre-wrap break-words",
          if(@long_content && !@expanded, do: "line-clamp-2")
        ]}>
          {@content_text}<span :if={@is_live} class="streaming-cursor"></span>
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.7; transition: opacity 200ms;"}
        >
          show more
        </button>
        <button
          :if={@long_content && @expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1 text-11 text-muted transition-opacity duration-200"
        >
          show less
        </button>
      </div>
    </div>
    """
  end

  # Context offload: compact single-row card
  defp render_event_card(assigns, %{type: :context_offload} = event) do
    config = @type_config.context_offload
    meta = Map.get(event, :metadata, %{})
    topic = meta[:topic]
    token_count = meta[:token_count]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:topic, topic)
      |> assign(:token_count, token_count)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          &#128230; offload
        </span>
        <span class="truncate min-w-0 text-xs text-secondary">
          {@event.content}
        </span>
        <span
          :if={@topic}
          class="flex-shrink-0"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.6;"}
        >
          ({@topic})
        </span>
        <span
          :if={@token_count}
          class="flex-shrink-0 text-11 font-mono text-muted"
        >
          {format_tokens(@token_count)} tok
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
    </div>
    """
  end

  # Question: highlighted, question mark icon, stands out for attention
  defp render_event_card(assigns, %{type: :question} = event) do
    config = @type_config.question
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:from, from)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid #{@config.accent_border}; border-left: 2px solid #{@config.accent}; border-radius: 0.5rem; box-shadow: 0 0 12px rgba(56, 189, 248, 0.08);"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@from)}; transition: opacity 200ms;"}
        >
          {@from}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          &#10068; question
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p style={"font-size: 0.8125rem; color: #{@config.accent_text}; line-height: 1.5; white-space: pre-wrap; word-break: break-word;"}>
          {@event.content}
        </p>
      </div>
    </div>
    """
  end

  # Answer: paired with question styling
  defp render_event_card(assigns, %{type: :answer} = event) do
    config = @type_config.answer
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent
    to = meta[:to]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:from, from)
      |> assign(:to, to)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@from)}; transition: opacity 200ms;"}
        >
          {@from}
        </button>
        <span class="text-11 text-muted">&#8594;</span>
        <span
          :if={@to}
          class="truncate"
          style={"font-size: 0.75rem; font-weight: 500; color: #{@config.accent_text};"}
        >
          {@to}
        </span>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          &#10069; answer
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class="text-13 text-primary leading-normal whitespace-pre-wrap break-words">
          {@event.content}
        </p>
      </div>
    </div>
    """
  end

  # Channel message: external channel indicator
  defp render_event_card(assigns, %{type: :channel_message} = event) do
    config = @type_config.channel_message
    meta = Map.get(event, :metadata, %{})
    channel = meta[:channel]
    direction = meta[:direction]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:channel, channel)
      |> assign(:direction, direction)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <span
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)};"}
        >
          {@event.agent}
        </span>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          {channel_icon(@channel)} {if @direction == :inbound, do: "received", else: "sent"}
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class="text-13 text-primary leading-normal whitespace-pre-wrap break-words">
          {@event.content}
        </p>
      </div>
    </div>
    """
  end

  # Decision: special treatment with brand accent
  defp render_event_card(assigns, %{type: :decision} = event) do
    config = @type_config.decision
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    content = event.content || ""
    long_content = String.length(content) > 200

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:content_text, content)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: #{@config.accent_bg}; border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          &#129504; decision
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p
          class={if @long_content && !@expanded, do: "line-clamp-3"}
          style={"font-size: 0.8125rem; color: #{@config.accent_text}; line-height: 1.5; white-space: pre-wrap; word-break: break-word;"}
        >
          {@content_text}
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1"
          style={"font-size: 0.6875rem; color: #{@config.accent_text}; opacity: 0.6; transition: opacity 200ms;"}
        >
          show more
        </button>
        <button
          :if={@long_content && @expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1 text-11 text-muted transition-opacity duration-200"
        >
          show less
        </button>
      </div>
    </div>
    """
  end

  # Fallback for any unknown event type
  defp render_event_card(assigns, event) do
    config = @type_config[event.type] || fallback_config()
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:expanded, expanded)

    ~H"""
    <div
      class="interactive overflow-hidden"
      style={"background: var(--surface-2); border: 1px solid var(--border-subtle); border-left: 2px solid #{@config.accent}; border-radius: 0.5rem;"}
    >
      <div class="flex items-center gap-2 px-3 py-2 min-w-0">
        <span
          class="flex-shrink-0"
          style={"width: 7px; height: 7px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
        >
        </span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="flex-shrink-0"
          style={"font-size: 0.75rem; font-weight: 600; color: #{agent_color(@event.agent)}; transition: opacity 200ms;"}
        >
          {@event.agent}
        </button>
        <span
          style={"display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px; border-radius: 9999px; font-size: 0.6875rem; font-weight: 500; background: #{@config.accent_bg}; color: #{@config.accent_text}; border: 1px solid #{@config.accent_border};"}
          class="flex-shrink-0"
        >
          {Phoenix.HTML.raw(@config.icon)} {@config.label}
        </span>
        <span class="ml-auto flex-shrink-0 text-11 font-mono text-muted">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class={[
          "text-xs text-secondary leading-normal break-words",
          if(!@expanded, do: "line-clamp-3")
        ]}>
          {@event.content}
        </p>
        <button
          :if={String.length(@event.content || "") > 200 && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="mt-1 text-11 text-brand transition-opacity duration-200"
        >
          show more
        </button>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp refilter_stream(socket) do
    filtered = apply_filters(socket.assigns.all_events, socket.assigns)
    stream(socket, :filtered_events, filtered, reset: true)
  end

  defp apply_filters(events, assigns) do
    events =
      case assigns.agent_filter do
        nil -> events
        agent -> Enum.filter(events, &(&1.agent == agent))
      end

    case MapSet.size(assigns.type_filter) do
      0 -> events
      _ -> Enum.filter(events, &MapSet.member?(assigns.type_filter, &1.type))
    end
  end

  defp event_matches_filter?(event, assigns) do
    agent_ok =
      case assigns.agent_filter do
        nil -> true
        agent -> event.agent == agent
      end

    type_ok =
      case MapSet.size(assigns.type_filter) do
        0 -> true
        _ -> MapSet.member?(assigns.type_filter, event.type)
      end

    agent_ok && type_ok
  end

  defp agent_color(agent_name), do: LoomkinWeb.AgentColors.agent_color(agent_name)

  defp extract_tool_name(content) when is_binary(content) do
    case Regex.run(~r/^used (\S+)/, content) do
      [_, name] ->
        name

      _ ->
        case Regex.run(~r/^(\S+) done:/, content) do
          [_, name] -> name
          _ -> "tool"
        end
    end
  end

  defp extract_tool_name(_), do: "tool"

  defp tool_icon(name) when is_binary(name) do
    cond do
      name in ~w(Read Write Edit Glob) -> "&#128196;"
      name in ~w(Bash shell exec) -> "&#9889;"
      name in ~w(Grep search) -> "&#128269;"
      name in ~w(decision plan) -> "&#129504;"
      true -> "&#9881;"
    end
  end

  defp tool_icon(_), do: "&#9881;"

  defp channel_icon(:telegram), do: Phoenix.HTML.raw("&#9992;")
  defp channel_icon(:discord), do: Phoenix.HTML.raw("&#127918;")
  defp channel_icon(_), do: Phoenix.HTML.raw("&#128172;")

  defp format_tokens(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n) when is_integer(n), do: to_string(n)
  defp format_tokens(_), do: "?"

  defp expand_label(true, true, cmd, result),
    do: "Details (#{format_result_size(cmd)} cmd + #{format_result_size(result)} output)"

  defp expand_label(true, false, cmd, _), do: "Command (#{format_result_size(cmd)})"
  defp expand_label(false, true, _, result), do: "Result (#{format_result_size(result)})"
  defp expand_label(_, _, _, _), do: "Details"

  defp format_result_size(str) when is_binary(str) do
    lines = str |> String.split("\n") |> length()
    chars = String.length(str)

    cond do
      lines > 1 -> "#{lines} lines"
      chars > 1000 -> "#{Float.round(chars / 1000, 1)}k chars"
      true -> "#{chars} chars"
    end
  end

  defp format_result_size(_), do: ""

  defp fallback_config do
    %{
      label: "event",
      icon: "&#9679;",
      accent: "#71717a",
      accent_bg: "rgba(113, 113, 122, 0.08)",
      accent_border: "rgba(113, 113, 122, 0.25)",
      accent_text: "#a1a1aa",
      dot_color: "#71717a"
    }
  end

  defp type_config_list do
    [
      {:tool_call, @type_config.tool_call},
      {:message, @type_config.message},
      {:task_created, @type_config.task_created},
      {:task_assigned, @type_config.task_assigned},
      {:task_complete, @type_config.task_complete},
      {:discovery, @type_config.discovery},
      {:error, @type_config.error},
      {:thinking, @type_config.thinking},
      {:agent_spawn, @type_config.agent_spawn},
      {:context_offload, @type_config.context_offload},
      {:question, @type_config.question},
      {:channel_message, @type_config.channel_message}
    ]
  end
end
