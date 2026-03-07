defmodule LoomkinWeb.ToolCallsComponent do
  @moduledoc """
  Minimalist collapsible feed for tool calls by all agents.

  Shows a compact feed of tool executions with:
  - Agent name
  - Tool name + target
  - Timestamp
  - Expandable result

  This keeps the main activity feed focused on high-signal events
  (thoughts, messages, decisions, discoveries, tasks).
  """

  use LoomkinWeb, :live_component

  import LoomkinWeb.TimeHelpers, only: [relative_time: 1]

  @tool_config %{
    "file_read" => %{icon: "&#128196;", color: "#818cf8"},
    "file_write" => %{icon: "&#9997;", color: "#34d399"},
    "file_edit" => %{icon: "&#9998;", color: "#fbbf24"},
    "file_search" => %{icon: "&#128269;", color: "#22d3ee"},
    "content_search" => %{icon: "&#128269;", color: "#22d3ee"},
    "directory_list" => %{icon: "&#128193;", color: "#a78bfa"},
    "shell" => %{icon: "&#9889;", color: "#f472b6"},
    "git" => %{icon: "&#128200;", color: "#fb923c"}
  }
  @default_tool_config %{icon: "&#9881;", color: "#71717a"}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded: false,
       expanded_ids: MapSet.new(),
       max_visible: 20
     )}
  end

  @impl true
  def update(assigns, socket) do
    tool_events = filter_tool_events(assigns[:events] || [])

    # Prune expanded_ids for events no longer in the feed
    expanded_ids = socket.assigns.expanded_ids
    event_ids = MapSet.new(tool_events, & &1.id)
    expanded_ids = MapSet.intersection(expanded_ids, event_ids)

    total_count = length(tool_events)
    recent_count = min(total_count, socket.assigns.max_visible)
    recent_events = tool_events |> Enum.take(-recent_count) |> Enum.reverse()

    {:ok,
     socket
     |> assign(:id, assigns[:id])
     |> assign(:events, tool_events)
     |> assign(:expanded_ids, expanded_ids)
     |> assign(:recent_events, recent_events)
     |> assign(:total_count, total_count)
     |> assign_new(:collapsed, fn -> true end)}
  end

  @impl true
  def handle_event("toggle_collapse", _params, socket) do
    {:noreply, assign(socket, collapsed: !socket.assigns.collapsed)}
  end

  def handle_event("expand_event", %{"id" => id}, socket) do
    expanded_ids = socket.assigns.expanded_ids

    expanded_ids =
      if MapSet.member?(expanded_ids, id),
        do: MapSet.delete(expanded_ids, id),
        else: MapSet.put(expanded_ids, id)

    {:noreply, assign(socket, expanded_ids: expanded_ids)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col border-t border-subtle">
      <%!-- Header: click to expand/collapse --%>
      <button
        phx-click="toggle_collapse"
        phx-target={@myself}
        class="flex items-center justify-between px-3 py-2 w-full text-left interactive bg-surface-1"
      >
        <div class="flex items-center gap-2">
          <svg
            class={[
              "w-3.5 h-3.5 text-muted transition-transform duration-200",
              if(!@collapsed, do: "rotate-90", else: "")
            ]}
            viewBox="0 0 20 20"
            fill="currentColor"
          >
            <path
              fill-rule="evenodd"
              d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z"
              clip-rule="evenodd"
            />
          </svg>
          <span class="text-[11px] font-medium text-muted">
            Tool Calls
          </span>
          <span class="text-[10px] px-1.5 py-0.5 rounded-full bg-surface-3 text-muted">
            {@total_count}
          </span>
        </div>
        <span :if={@total_count > 0} class="text-[10px] text-muted">
          {if @collapsed, do: "click to expand", else: "click to collapse"}
        </span>
      </button>

      <%!-- Collapsible tool calls feed --%>
      <div
        :if={!@collapsed && @total_count > 0}
        class="overflow-auto max-h-64 animate-fade-in bg-surface-0"
      >
        <div class="px-3 py-2 space-y-1">
          <div :for={event <- @recent_events} class="tool-call-item">
            {render_tool_call(assigns, event)}
          </div>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={!@collapsed && @total_count == 0}
        class="px-3 py-4 text-center bg-surface-0"
      >
        <span class="text-xs text-muted">No tool calls yet</span>
      </div>
    </div>
    """
  end

  defp render_tool_call(assigns, event) do
    meta = event.metadata || %{}
    tool_name = meta[:tool_name] || "tool"
    file_path = meta[:file_path]
    result = meta[:result]
    has_result = is_binary(result) and result != ""
    expanded = MapSet.member?(assigns.expanded_ids, event.id)
    config = Map.get(@tool_config, String.downcase(tool_name), @default_tool_config)

    assigns =
      assigns
      |> assign(:event, event)
      |> assign(:tool_name, tool_name)
      |> assign(:file_path, file_path)
      |> assign(:result, result)
      |> assign(:has_result, has_result)
      |> assign(:expanded, expanded)
      |> assign(:config, config)

    ~H"""
    <div
      class={[
        "flex items-start gap-2 py-1.5 px-2 rounded transition-colors",
        @has_result && "cursor-pointer hover:bg-white/5"
      ]}
      phx-click={if @has_result, do: "expand_event"}
      phx-target={if @has_result, do: @myself}
      phx-value-id={if @has_result, do: @event.id}
    >
      <%!-- Agent dot --%>
      <span
        class="flex-shrink-0 mt-0.5"
        style={"width: 5px; height: 5px; border-radius: 9999px; background-color: #{agent_color(@event.agent)};"}
      >
      </span>

      <%!-- Agent name --%>
      <span
        class="flex-shrink-0 text-[10px] font-medium"
        style={"color: #{agent_color(@event.agent)};"}
      >
        {@event.agent}
      </span>

      <%!-- Tool icon + name --%>
      <span
        class="flex-shrink-0 text-[10px]"
        style={"color: #{@config.color};"}
      >
        {Phoenix.HTML.raw(@config.icon)} {@tool_name}
      </span>

      <%!-- Target file/path --%>
      <span
        :if={@file_path}
        class="flex-shrink truncate text-[10px] font-mono text-muted max-w-[120px]"
        title={@file_path}
      >
        {Path.basename(@file_path)}
      </span>

      <%!-- Timestamp --%>
      <span class="ml-auto flex-shrink-0 text-[9px] font-mono text-muted">
        {relative_time(@event.timestamp)}
      </span>
    </div>

    <%!-- Result preview (on hover/expand) --%>
    <div :if={@has_result && @expanded} class="ml-6 mt-1 mb-2">
      <pre class="overflow-auto text-[10px] font-mono text-muted whitespace-pre-wrap break-all bg-surface-2 border border-subtle rounded px-2 py-1.5 max-h-32">{String.slice(@result, 0, 500)}{if String.length(@result) > 500, do: "...", else: ""}</pre>
    </div>
    """
  end

  # --- Helpers ---

  defp filter_tool_events(events) do
    Enum.filter(events, fn event ->
      event.type in [:tool_call, :context_offload]
    end)
  end

  defp agent_color(agent_name), do: LoomkinWeb.AgentColors.agent_color(agent_name)
end
