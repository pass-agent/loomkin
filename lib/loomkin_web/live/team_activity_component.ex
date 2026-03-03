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

  @agent_colors [
    "#818cf8",
    "#34d399",
    "#f472b6",
    "#fb923c",
    "#22d3ee",
    "#a78bfa",
    "#fbbf24",
    "#4ade80"
  ]

  @type_config %{
    tool_call: %{label: "tool", icon: "&#9881;", bg: "bg-violet-400/20", text: "text-violet-400", border: "border-violet-500/40", card_bg: "bg-gray-900/50"},
    message: %{label: "message", icon: "&#9993;", bg: "bg-emerald-400/20", text: "text-emerald-400", border: "border-emerald-500/40", card_bg: "bg-gray-900/50"},
    decision: %{label: "decision", icon: "&#129504;", bg: "bg-purple-400/20", text: "text-purple-400", border: "border-purple-500/40", card_bg: "bg-gray-900/50"},
    task_created: %{label: "created", icon: "&#10010;", bg: "bg-cyan-400/20", text: "text-cyan-400", border: "border-cyan-500/40", card_bg: "bg-gray-900/50"},
    task_assigned: %{label: "assigned", icon: "&#10132;", bg: "bg-blue-400/20", text: "text-blue-400", border: "border-blue-500/40", card_bg: "bg-gray-900/50"},
    task_started: %{label: "started", icon: "&#9654;", bg: "bg-violet-400/20", text: "text-violet-400", border: "border-violet-500/40", card_bg: "bg-gray-900/50"},
    task_complete: %{label: "done", icon: "&#10004;", bg: "bg-green-400/20", text: "text-green-400", border: "border-green-500/40", card_bg: "bg-green-950/20"},
    task_failed: %{label: "failed", icon: "&#10006;", bg: "bg-red-400/20", text: "text-red-400", border: "border-red-500/40", card_bg: "bg-red-950/20"},
    discovery: %{label: "discovery", icon: "&#11088;", bg: "bg-yellow-400/20", text: "text-yellow-400", border: "border-yellow-500/40", card_bg: "bg-yellow-950/10"},
    error: %{label: "error", icon: "&#9888;", bg: "bg-red-400/20", text: "text-red-400", border: "border-red-500/40", card_bg: "bg-red-950/30"},
    thinking: %{label: "thinking", icon: "&#8230;", bg: "bg-indigo-400/20", text: "text-indigo-400", border: "border-indigo-500/40", card_bg: "bg-gray-900/50"},
    streaming: %{label: "thinking", icon: "&#8230;", bg: "bg-indigo-400/20", text: "text-indigo-400", border: "border-indigo-500/40", card_bg: "bg-gray-900/50"},
    agent_spawn: %{label: "joined", icon: "&#10035;", bg: "bg-teal-400/20", text: "text-teal-400", border: "border-teal-500/40", card_bg: "bg-teal-500/5"},
    context_offload: %{label: "offload", icon: "&#128230;", bg: "bg-amber-400/20", text: "text-amber-400", border: "border-amber-500/40", card_bg: "bg-gray-900/50"},
    question: %{label: "question", icon: "&#10068;", bg: "bg-sky-400/20", text: "text-sky-400", border: "border-sky-500/40", card_bg: "bg-sky-950/15"},
    answer: %{label: "answer", icon: "&#10069;", bg: "bg-sky-400/20", text: "text-sky-400", border: "border-sky-500/40", card_bg: "bg-gray-900/50"},
    channel_message: %{label: "channel", icon: "&#128172;", bg: "bg-cyan-400/20", text: "text-cyan-400", border: "border-cyan-500/40", card_bg: "bg-gray-900/50"}
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       events: [],
       known_agents: [],
       focused_agent: nil,
       agent_filter: nil,
       type_filter: MapSet.new(),
       expanded_ids: MapSet.new()
     )}
  end

  @impl true
  def update(assigns, socket) do
    events = assigns[:events] || socket.assigns.events

    # Prune expanded_ids for events no longer in the feed
    expanded_ids = socket.assigns.expanded_ids
    event_ids = MapSet.new(events, & &1.id)
    expanded_ids = MapSet.intersection(expanded_ids, event_ids)

    socket =
      socket
      |> assign(:team_id, assigns[:team_id])
      |> assign(:id, assigns[:id])
      |> assign(:events, events)
      |> assign(:known_agents, assigns[:known_agents] || socket.assigns.known_agents)
      |> assign(:expanded_ids, expanded_ids)

    # Accept focused_agent from parent (e.g. roster click) — auto-apply as agent filter
    socket =
      case assigns[:focused_agent] do
        nil -> socket
        agent -> assign(socket, focused_agent: agent, agent_filter: agent)
      end

    {:ok, socket}
  end

  # --- UI Event Handlers ---

  @impl true
  def handle_event("filter_agent", %{"agent" => ""}, socket) do
    {:noreply, assign(socket, agent_filter: nil, focused_agent: nil)}
  end

  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    current = socket.assigns.agent_filter
    new_filter = if(current == agent, do: nil, else: agent)
    {:noreply, assign(socket, agent_filter: new_filter, focused_agent: nil)}
  end

  def handle_event("toggle_type", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    filter = socket.assigns.type_filter

    new_filter =
      if MapSet.member?(filter, type),
        do: MapSet.delete(filter, type),
        else: MapSet.put(filter, type)

    {:noreply, assign(socket, type_filter: new_filter)}
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
    assigns = assign(assigns, :filtered_events, filtered_events(assigns))

    ~H"""
    <div class="flex flex-col h-full bg-gray-950">
      <%!-- Filter Bar --%>
      <div class="flex flex-col border-b border-gray-800">
        <%!-- Agent Filters --%>
        <div class="flex flex-wrap items-center gap-1.5 px-4 py-2">
          <button
            phx-click="filter_agent"
            phx-value-agent=""
            phx-target={@myself}
            class={"text-xs px-2.5 py-1 rounded-full font-medium transition #{if @agent_filter == nil, do: "bg-violet-600 text-white", else: "bg-gray-800 text-gray-400 hover:text-gray-200"}"}
          >
            All
          </button>
          <button
            :for={agent <- @known_agents}
            phx-click="filter_agent"
            phx-value-agent={agent}
            phx-target={@myself}
            class={"flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full font-medium transition #{if @agent_filter == agent, do: "bg-gray-700 text-white ring-1 ring-gray-600", else: "bg-gray-800 text-gray-400 hover:text-gray-200"}"}
          >
            <span class="w-2 h-2 rounded-full flex-shrink-0" style={"background-color: #{agent_color(agent)}"}></span>
            {agent}
          </button>
        </div>

        <%!-- Type Filters --%>
        <div class="flex flex-wrap items-center gap-1.5 px-4 py-1.5 border-t border-gray-800/50">
          <button
            :for={{type, config} <- type_config_list()}
            phx-click="toggle_type"
            phx-value-type={type}
            phx-target={@myself}
            class={"text-xs px-2 py-0.5 rounded-full font-medium transition #{if MapSet.size(@type_filter) > 0 && !MapSet.member?(@type_filter, type), do: "opacity-30", else: ""} #{config.bg} #{config.text}"}
          >
            {config.label}
          </button>
        </div>
      </div>

      <%!-- Event Feed --%>
      <div class="flex-1 overflow-auto" id={"activity-feed-#{@id}"} phx-hook="ScrollToBottom">
        <div class="flex flex-col gap-1 p-2">
          <div
            :if={@filtered_events == []}
            class="flex items-center justify-center h-48 text-gray-500"
          >
            <div class="text-center space-y-2">
              <div class="text-3xl opacity-50">&#9673;</div>
              <p class="text-sm">No activity yet</p>
              <p class="text-xs text-gray-600">Events will appear here as your team works</p>
            </div>
          </div>

          <div :for={event <- @filtered_events}>
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
    meta = Map.get(event, :metadata, %{})
    tool_name = meta[:tool_name] || extract_tool_name(event.content)
    file_path = meta[:file_path]
    result_preview = meta[:result] || meta[:result_preview]
    has_result = is_binary(result_preview) and result_preview != ""
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:tool_name, tool_name)
      |> assign(:file_path, file_path)
      |> assign(:result_preview, result_preview)
      |> assign(:has_result, has_result)
      |> assign(:expanded, expanded)

    ~H"""
    <div class="rounded bg-gray-900/50 hover:bg-gray-900/80 transition border-l-2 border-violet-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class="text-xs px-1.5 py-0.5 rounded bg-violet-400/20 text-violet-400 font-medium">
          {tool_icon(@tool_name)} {@tool_name}
        </span>
        <span :if={@file_path} class="text-xs text-gray-500 truncate max-w-[200px]">
          <button
            phx-click="inspect_file"
            phx-value-path={@file_path}
            phx-target={@myself}
            class="text-violet-400/70 hover:text-violet-300 font-mono transition"
          >
            {Path.basename(@file_path)}
          </button>
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Collapsible result --%>
      <div :if={@has_result} class="px-3 pb-1.5">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-gray-500 hover:text-gray-300 transition"
        >
          &#9656; Result ({format_result_size(@result_preview)})
        </button>
        <div :if={@expanded}>
          <pre class="text-xs text-gray-400 font-mono whitespace-pre-wrap bg-gray-950/50 rounded p-2 max-h-64 overflow-auto mt-1">{@result_preview}</pre>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="text-xs text-gray-500 hover:text-gray-300 mt-1 transition"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
      <%!-- Fallback: show content if no result --%>
      <div :if={!@has_result && String.length(@event.content) > 0} class="px-3 pb-1.5">
        <p class="text-xs text-gray-400">{@event.content}</p>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Message: agent -> recipient, content truncated with expand
  defp render_event_card(assigns, %{type: :message} = event) do
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent
    to = meta[:to]
    display_to = if to, do: to, else: "Team"
    content = event.content || ""
    long_content = String.length(content) > 280
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:from, from)
      |> assign(:display_to, display_to)
      |> assign(:content_text, content)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div class="rounded bg-gray-900/50 hover:bg-gray-900/80 transition border-l-2 border-emerald-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@from}
        </button>
        <span class="text-xs text-gray-600">&#8594;</span>
        <span class="text-xs font-medium text-emerald-400">{@display_to}</span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class={"text-sm text-gray-300 leading-snug whitespace-pre-wrap #{if @long_content && !@expanded, do: "line-clamp-3"}"}>
          {@content_text}
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-emerald-400/70 hover:text-emerald-300 mt-0.5 transition"
        >
          show more
        </button>
        <button
          :if={@long_content && @expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-gray-500 hover:text-gray-300 mt-0.5 transition"
        >
          show less
        </button>
      </div>
      {reply_button(assign(assigns, :agent, @from))}
    </div>
    """
  end

  # Task lifecycle: distinct icons per state, title + owner in header
  defp render_event_card(assigns, %{type: type} = event)
       when type in [:task_created, :task_assigned, :task_started, :task_complete, :task_failed] do
    meta = Map.get(event, :metadata, %{})
    config = Map.get(@type_config, type, %{label: to_string(type), icon: "&#9679;", bg: "bg-gray-400/20", text: "text-gray-400", border: "border-gray-500/40", card_bg: "bg-gray-900/50"})
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
    <div class={"rounded hover:bg-gray-900/80 transition border-l-2 #{@config.border} overflow-hidden #{@config.card_bg}"}>
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class={"text-xs px-1.5 py-0.5 rounded font-medium #{@config.bg} #{@config.text}"}>
          {Phoenix.HTML.raw(@config.icon)} {@config.label}
        </span>
        <span :if={@title} class="text-xs text-gray-300 truncate font-medium">{@title}</span>
        <span :if={@owner} class="text-xs text-gray-500">
          &#8594; <span class="text-gray-400">{@owner}</span>
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Show content only when there is no title (fallback) --%>
      <div :if={!@title && @event.content != ""} class="px-3 pb-1.5">
        <p class="text-xs text-gray-400">{@event.content}</p>
      </div>
      <%!-- Collapsible result for completed tasks --%>
      <div :if={@result && @event.type == :task_complete} class="px-3 pb-1.5">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-gray-500 hover:text-gray-300 transition"
        >
          &#9656; Show result
        </button>
        <div :if={@expanded}>
          <pre class="text-xs text-gray-400 font-mono whitespace-pre-wrap bg-gray-950/50 rounded p-2 max-h-48 overflow-auto">{@result}</pre>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="text-xs text-gray-500 hover:text-gray-300 mt-1 transition"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Discovery: highlighted background, star icon, content always visible
  defp render_event_card(assigns, %{type: :discovery} = event) do
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    content = event.content || ""
    long_content = String.length(content) > 200

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:content_text, content)
      |> assign(:long_content, long_content)
      |> assign(:expanded, expanded)

    ~H"""
    <div class="rounded bg-yellow-950/10 hover:bg-yellow-950/20 transition border-l-2 border-yellow-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-yellow-400/20 text-yellow-400">
          &#11088; discovery
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class={"text-sm text-yellow-200/80 leading-snug whitespace-pre-wrap #{if @long_content && !@expanded, do: "line-clamp-2"}"}>
          {@content_text}
        </p>
        <button
          :if={@long_content && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-yellow-400/60 hover:text-yellow-300 mt-0.5 transition"
        >
          show more
        </button>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Agent spawn: centered banner style, compact
  defp render_event_card(assigns, %{type: :agent_spawn} = event) do
    meta = Map.get(event, :metadata, %{})
    role = meta[:role]
    model = meta[:model]
    agent_name = meta[:agent_name] || event.agent

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:agent_name, agent_name)
      |> assign(:role, role)
      |> assign(:model, model)

    ~H"""
    <div class="rounded bg-teal-500/5 border border-teal-500/20 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-2 h-2 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@agent_name)}"}></span>
        <span class="text-xs font-medium text-teal-300">&#10035; {@agent_name} joined</span>
        <span :if={@role} class="text-xs text-gray-500">as <span class="text-gray-400">{@role}</span></span>
        <span :if={@model} class="text-xs text-gray-600 ml-auto">{@model}</span>
        <span :if={!@model} class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
    </div>
    """
  end

  # Error: red tint, warning icon, error message in header, details collapsible
  defp render_event_card(assigns, %{type: :error} = event) do
    meta = Map.get(event, :metadata, %{})
    details = meta[:details]
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    content = event.content || ""
    # Show brief error inline in header if short enough
    brief_error = String.length(content) <= 120

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:details, details)
      |> assign(:expanded, expanded)
      |> assign(:brief_error, brief_error)
      |> assign(:content_text, content)

    ~H"""
    <div class="rounded bg-red-950/30 hover:bg-red-950/50 transition border-l-2 border-red-500/60 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-red-400/20 text-red-400">
          &#9888; error
        </span>
        <span :if={@brief_error && @content_text != ""} class="text-xs text-red-300/80 truncate">{@content_text}</span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <%!-- Full error content if too long for header --%>
      <div :if={!@brief_error} class="px-3 pb-1.5">
        <p class="text-xs text-red-300/80">{@content_text}</p>
      </div>
      <%!-- Collapsible details (stack trace etc.) --%>
      <div :if={@details} class="px-3 pb-1.5">
        <button
          :if={!@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-gray-500 hover:text-gray-300 transition"
        >
          &#9656; Show details
        </button>
        <div :if={@expanded}>
          <pre class="text-xs text-red-300/70 font-mono whitespace-pre-wrap bg-gray-950/50 rounded p-2 max-h-48 overflow-auto">{@details}</pre>
          <button
            phx-click="expand_event"
            phx-value-id={@event.id}
            phx-target={@myself}
            class="text-xs text-gray-500 hover:text-gray-300 mt-1 transition"
          >
            &#9662; Collapse
          </button>
        </div>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Thinking/Streaming: subtle, with animated cursor for live streams
  defp render_event_card(assigns, %{type: type} = event) when type in [:thinking, :streaming] do
    meta = Map.get(event, :metadata, %{})
    streaming_content = meta[:content]
    is_live = type == :streaming

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:streaming_content, streaming_content)
      |> assign(:is_live, is_live)

    ~H"""
    <div class={"rounded bg-gray-900/40 transition border-l-2 border-indigo-500/30 overflow-hidden #{if @is_live, do: "ring-1 ring-indigo-500/20 animate-pulse-subtle"}"}>
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-400 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class="text-xs text-indigo-400/60">thinking&#8230;</span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div :if={@streaming_content || @event.content != ""} class="px-3 pb-1.5">
        <p class="text-xs text-gray-500 leading-snug whitespace-pre-wrap line-clamp-2">
          {@streaming_content || @event.content}<span :if={@is_live} class="inline-block w-1 h-3 bg-indigo-400 animate-pulse ml-0.5 align-text-bottom"></span>
        </p>
      </div>
    </div>
    """
  end

  # Context offload: compact single-row card
  defp render_event_card(assigns, %{type: :context_offload} = event) do
    meta = Map.get(event, :metadata, %{})
    topic = meta[:topic]
    token_count = meta[:token_count]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:topic, topic)
      |> assign(:token_count, token_count)

    ~H"""
    <div class="rounded bg-gray-900/50 hover:bg-gray-900/80 transition border-l-2 border-amber-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-amber-400/20 text-amber-400">
          &#128230; offload
        </span>
        <span class="text-xs text-gray-400">{@event.content}</span>
        <span :if={@topic} class="text-xs text-amber-400/60">({@topic})</span>
        <span :if={@token_count} class="text-xs text-gray-600">{format_tokens(@token_count)} tok</span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Question: highlighted, question mark icon, stands out for attention
  defp render_event_card(assigns, %{type: :question} = event) do
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:from, from)

    ~H"""
    <div class="rounded bg-sky-950/15 hover:bg-sky-950/25 transition border-l-2 border-sky-500/50 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@from}
        </button>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-sky-400/20 text-sky-400">
          &#10068; question
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class="text-sm text-sky-200/80 leading-snug whitespace-pre-wrap">{@event.content}</p>
      </div>
      {reply_button(assign(assigns, :agent, @from))}
    </div>
    """
  end

  # Answer: paired with question styling
  defp render_event_card(assigns, %{type: :answer} = event) do
    meta = Map.get(event, :metadata, %{})
    from = meta[:from] || event.agent
    to = meta[:to]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:from, from)
      |> assign(:to, to)

    ~H"""
    <div class="rounded bg-gray-900/50 hover:bg-gray-900/80 transition border-l-2 border-sky-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@from}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@from}
        </button>
        <span class="text-xs text-gray-600">&#8594;</span>
        <span :if={@to} class="text-xs font-medium text-sky-400">{@to}</span>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-sky-400/20 text-sky-400">
          &#10069; answer
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class="text-sm text-gray-300 leading-snug whitespace-pre-wrap">{@event.content}</p>
      </div>
      {reply_button(assign(assigns, :agent, @from))}
    </div>
    """
  end

  # Channel message: external channel indicator
  defp render_event_card(assigns, %{type: :channel_message} = event) do
    meta = Map.get(event, :metadata, %{})
    channel = meta[:channel]
    direction = meta[:direction]

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:channel, channel)
      |> assign(:direction, direction)

    ~H"""
    <div class="rounded bg-gray-900/50 hover:bg-gray-900/80 transition border-l-2 border-cyan-500/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <span class="text-xs font-semibold text-gray-300">
          {@event.agent}
        </span>
        <span class="text-xs px-1.5 py-0.5 rounded font-medium bg-cyan-400/20 text-cyan-400">
          {channel_icon(@channel)} {if @direction == :inbound, do: "received", else: "sent"}
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-2">
        <p class="text-sm text-gray-300 leading-snug whitespace-pre-wrap">{@event.content}</p>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # Fallback for any unknown event type
  defp render_event_card(assigns, event) do
    config = Map.get(@type_config, event.type, %{label: to_string(event.type), icon: "&#9679;", bg: "bg-gray-400/20", text: "text-gray-400", border: "border-gray-500/40", card_bg: "bg-gray-900/50"})
    expanded = MapSet.member?(assigns.expanded_ids, event.id)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:config, config)
      |> assign(:expanded, expanded)

    ~H"""
    <div class={"rounded hover:bg-gray-900/80 transition border-l-2 #{@config.border} overflow-hidden #{@config.card_bg}"}>
      <div class="flex items-center gap-2 px-3 py-1.5">
        <span class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background-color: #{agent_color(@event.agent)}"}></span>
        <button
          phx-click="focus_agent"
          phx-value-agent={@event.agent}
          phx-target={@myself}
          class="text-xs font-semibold text-gray-300 hover:text-white transition"
        >
          {@event.agent}
        </button>
        <span class={"text-xs px-1.5 py-0.5 rounded font-medium #{@config.bg} #{@config.text}"}>
          {Phoenix.HTML.raw(@config.icon)} {@config.label}
        </span>
        <span class="text-xs text-gray-600 ml-auto flex-shrink-0">
          {relative_time(@event.timestamp)}
        </span>
      </div>
      <div class="px-3 pb-1.5">
        <p class={"text-xs text-gray-400 leading-snug #{if !@expanded, do: "line-clamp-3"}"}>
          {@event.content}
        </p>
        <button
          :if={String.length(@event.content || "") > 200 && !@expanded}
          phx-click="expand_event"
          phx-value-id={@event.id}
          phx-target={@myself}
          class="text-xs text-violet-400 hover:text-violet-300 mt-0.5 transition"
        >
          show more
        </button>
      </div>
      {reply_button(assign(assigns, :agent, @event.agent))}
    </div>
    """
  end

  # --- Helpers ---

  defp reply_button(assigns) do
    ~H"""
    <button
      :if={@agent != "You" && @agent != "system"}
      phx-click="reply_to_agent"
      phx-value-agent={@agent}
      class="flex items-center gap-1 text-xs text-gray-500/60 hover:text-emerald-400 transition px-3 pb-1.5"
      title={"Reply to #{@agent}"}
    >
      <svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" d="M3 10h10a5 5 0 015 5v4M3 10l5 5M3 10l5-5" />
      </svg>
      Reply
    </button>
    """
  end

  defp filtered_events(assigns) do
    events = assigns.events

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

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 3 -> "now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp agent_color(agent_name) do
    index = :erlang.phash2(agent_name, length(@agent_colors))
    Enum.at(@agent_colors, index)
  end

  defp extract_tool_name(content) when is_binary(content) do
    case Regex.run(~r/^used (\S+)/, content) do
      [_, name] -> name
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
