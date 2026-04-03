defmodule LoomkinWeb.ContextInspectorComponent do
  @moduledoc """
  Right-panel agent deep-focus sidebar for Mission Control mode.

  Always agent-scoped — shows the focused agent's activity stream.
  When no agent is focused, shows a prompt to select one.
  """

  use LoomkinWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, collapsed: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_collapse", _params, socket) do
    {:noreply, assign(socket, collapsed: !socket.assigns.collapsed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="inspector-panel" class={panel_class(@collapsed)} phx-hook="ResizablePanel">
      <.resize_handle collapsed={@collapsed} />
      <%= if @collapsed do %>
        <.collapsed_strip myself={@myself} />
      <% else %>
        <%= if @focused_agent && @focused_card do %>
          <.agent_header
            focused_agent={@focused_agent}
            focused_card={@focused_card}
            inspector_mode={@inspector_mode}
            myself={@myself}
          />
          <div id="inspector-agent-content" class="flex-1 overflow-auto min-h-0 relative bg-surface-0">
            <div class="h-full">
              {render_activity(assigns)}
            </div>
          </div>
        <% else %>
          <.empty_state myself={@myself} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Agent header ────────────────────────────────────────────────────

  defp agent_header(assigns) do
    color = agent_color(assigns.focused_agent)
    assigns = assign(assigns, :color, color)

    ~H"""
    <div
      class="flex items-center gap-2 px-3 py-2.5 flex-shrink-0"
      style={"background: linear-gradient(135deg, #{@color}06, transparent 60%);"}
    >
      <span class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{@color};"} />
      <span class="text-xs font-semibold truncate" style={"color: #{@color};"}>
        {@focused_agent}
      </span>
      <span
        :if={@focused_card[:role]}
        class="text-[10px] px-1.5 py-0.5 rounded font-medium text-muted"
        style={"background: #{@color}12;"}
      >
        {format_role(@focused_card.role)}
      </span>
      <div class="ml-auto flex items-center gap-1.5">
        <button
          phx-click="toggle_collapse"
          phx-target={@myself}
          class="interactive p-1 rounded-md text-muted"
          title="Collapse panel"
        >
          <.icon name="hero-chevron-right-mini" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # ── Empty state (no agent focused) ──────────────────────────────────

  defp empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col items-center justify-center p-8 bg-surface-0">
      <div class="w-10 h-10 rounded-xl bg-surface-2 flex items-center justify-center mb-4">
        <.icon name="hero-eye-mini" class="w-5 h-5 text-muted" />
      </div>
      <p class="text-sm font-medium text-secondary mb-1">Agent inspector</p>
      <p class="text-xs text-muted text-center leading-relaxed max-w-[200px] mb-6">
        Click any agent card on the left to inspect their work here
      </p>
      <button
        phx-click="toggle_collapse"
        phx-target={@myself}
        class="text-[11px] px-3 py-1.5 rounded-lg text-muted bg-surface-2 hover:text-secondary transition-colors"
      >
        Collapse panel
      </button>
    </div>
    """
  end

  # ── Shared sub-components ───────────────────────────────────────────

  defp resize_handle(assigns) do
    ~H"""
    <div
      :if={!@collapsed}
      id="inspector-resize-handle"
      class="hidden xl:flex absolute left-0 top-0 bottom-0 w-1 cursor-col-resize z-10 items-center justify-center group hover:bg-violet-500/20 active:bg-violet-500/30 transition-[background] duration-150"
    >
      <div class="w-0.5 h-8 rounded-full bg-zinc-700/40 group-hover:bg-violet-400 group-active:bg-violet-400 transition-[background] duration-150">
      </div>
    </div>
    """
  end

  defp collapsed_strip(assigns) do
    ~H"""
    <div class="flex h-full w-full items-center justify-center gap-0.5 px-1 py-1 xl:flex-col xl:items-center xl:justify-start xl:px-0 xl:py-1.5 bg-surface-1">
      <button
        phx-click="toggle_collapse"
        phx-target={@myself}
        class="interactive p-1.5 rounded-md text-muted"
        title="Expand inspector"
      >
        <.icon name="hero-chevron-left-mini" class="w-3 h-3" />
      </button>
    </div>
    """
  end

  # ── Tab content ─────────────────────────────────────────────────────

  defp render_activity(assigns) do
    color = agent_color(assigns.focused_agent)
    assigns = assign(assigns, :color, color)

    ~H"""
    <div class="p-3 space-y-3 h-full flex flex-col">
      <%!-- Current status --%>
      <div class="flex items-center gap-2 flex-shrink-0">
        <span class={[
          "w-1.5 h-1.5 rounded-full flex-shrink-0",
          agent_status_dot(@focused_card.status)
        ]} />
        <span class="text-[10px] font-medium uppercase tracking-wider text-muted">
          {format_status(@focused_card.status)}
        </span>
        <span
          :if={@focused_card[:current_task]}
          class="text-[10px] font-mono truncate text-secondary"
        >
          — {@focused_card.current_task}
        </span>
      </div>

      <%!-- Current tool indicator --%>
      <div
        :if={@focused_card[:last_tool]}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-surface-1/80 flex-shrink-0"
      >
        <span class="text-xs">{tool_emoji(@focused_card.last_tool.name)}</span>
        <span class="text-[11px] font-mono truncate text-secondary">
          {@focused_card.last_tool.target || @focused_card.last_tool.name}
        </span>
      </div>

      <%!-- Scrollable thought history --%>
      <div
        id={"inspector-thought-history-#{@focused_agent}"}
        phx-hook="ScrollToBottom"
        class="flex-1 overflow-y-auto min-h-0 space-y-2 thought-history-scroll"
      >
        <%!-- Past thoughts --%>
        <%= for {entry, idx} <- Enum.with_index(Map.get(@focused_card, :thought_history, [])) do %>
          <div
            id={"inspector-thought-#{idx}"}
            class="rounded-xl bg-surface-1/80 p-3 opacity-70"
          >
            <div class="flex items-center gap-1.5 mb-1.5">
              <span class={inspector_thought_badge_class(entry.type)}>
                {inspector_thought_label(entry.type)}
              </span>
              <span class="text-[9px] text-muted/40 font-mono ml-auto">
                {format_inspector_time(entry.timestamp)}
              </span>
            </div>
            <div class="text-xs leading-relaxed text-secondary agent-card-content line-clamp-8">
              {render_markdown(entry.content)}
            </div>
          </div>
        <% end %>

        <%!-- Current live thought/message --%>
        <%= case @focused_card.content_type do %>
          <% :thinking -> %>
            <div class="rounded-xl bg-surface-1/80 p-3.5">
              <div class="flex items-center gap-1.5 mb-2">
                <span class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-pulse" />
                <span class="text-[10px] font-medium text-violet-400 uppercase tracking-wider">
                  Thinking
                </span>
              </div>
              <div class="text-xs leading-relaxed text-secondary agent-card-content">
                {render_markdown(@focused_card.latest_content)}
              </div>
            </div>
          <% :last_thinking -> %>
            <div class="rounded-xl bg-surface-1/80 p-3.5 opacity-60">
              <div class="flex items-center gap-1.5 mb-2">
                <span class="text-[10px] font-medium text-muted uppercase tracking-wider">
                  Last thought
                </span>
              </div>
              <div class="text-xs leading-relaxed text-secondary agent-card-content">
                {render_markdown(@focused_card.latest_content)}
              </div>
            </div>
          <% :message -> %>
            <div class="rounded-xl bg-surface-1/80 p-3.5">
              <div class="flex items-center gap-1.5 mb-2">
                <span class="text-[10px] font-medium text-emerald-400 uppercase tracking-wider">
                  Response
                </span>
              </div>
              <div class="text-xs leading-relaxed text-secondary agent-card-content">
                {render_markdown(@focused_card.latest_content)}
              </div>
            </div>
          <% _ -> %>
            <%= if @focused_card[:last_response] do %>
              <div class="rounded-xl bg-surface-1/80 p-3.5 opacity-60">
                <div class="flex items-center gap-1.5 mb-2">
                  <span class="text-[10px] font-medium text-muted uppercase tracking-wider">
                    Last response
                  </span>
                </div>
                <div class="text-xs leading-relaxed text-secondary agent-card-content">
                  {render_markdown(@focused_card.last_response)}
                </div>
              </div>
            <% else %>
              <%= if Map.get(@focused_card, :thought_history, []) == [] do %>
                <div class="rounded-xl py-8 text-center">
                  <p class="text-xs text-muted italic">
                    <%= if @focused_card.status == :complete do %>
                      Agent has completed its work
                    <% else %>
                      Waiting for activity...
                    <% end %>
                  </p>
                </div>
              <% end %>
            <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Styling helpers ─────────────────────────────────────────────────

  defp panel_class(true = _collapsed),
    do:
      "inspector-panel inspector-collapsed w-full h-10 xl:w-9 xl:h-full flex flex-col bg-surface-1 transition-all duration-300 ease-in-out"

  defp panel_class(false = _collapsed),
    do:
      "inspector-panel relative w-full h-[20rem] xl:w-80 xl:h-full flex-shrink-0 flex flex-col bg-surface-1/80 backdrop-blur-sm transition-colors duration-300 ease-in-out"

  # ── Data helpers ────────────────────────────────────────────────────

  defp agent_color(name), do: LoomkinWeb.AgentColors.agent_color(name)

  defp agent_status_dot(:working), do: "bg-green-400 agent-dot-working"
  defp agent_status_dot(:idle), do: "bg-zinc-500"
  defp agent_status_dot(:blocked), do: "bg-amber-400"
  defp agent_status_dot(:paused), do: "bg-blue-400 animate-pulse"
  defp agent_status_dot(:error), do: "bg-red-400"
  defp agent_status_dot(:complete), do: "bg-emerald-400"
  defp agent_status_dot(_), do: "bg-zinc-500"

  defp format_status(:working), do: "Working"
  defp format_status(:idle), do: "Idle"
  defp format_status(:blocked), do: "Blocked"
  defp format_status(:paused), do: "Paused"
  defp format_status(:error), do: "Error"
  defp format_status(:waiting_permission), do: "Awaiting permission"
  defp format_status(:complete), do: "Complete"
  defp format_status(_), do: "Unknown"

  defp format_role(role) when is_atom(role) or is_binary(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_role(_), do: ""

  @tool_emojis %{
    "file_read" => "📄",
    "file_write" => "✍",
    "file_edit" => "✎",
    "file_search" => "🔍",
    "content_search" => "🔍",
    "directory_list" => "📁",
    "shell" => "⚡",
    "git" => "📈"
  }

  defp tool_emoji(name) when is_binary(name), do: Map.get(@tool_emojis, name, "⚙")
  defp tool_emoji(_), do: "⚙"

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(content) when is_binary(content) do
    doc =
      MDEx.new(render: [unsafe_: true])
      |> MDEx.Document.put_markdown(String.trim(content))

    case MDEx.to_html(doc) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> Phoenix.HTML.raw("<p>#{Phoenix.HTML.html_escape(content) |> elem(1)}</p>")
    end
  end

  defp render_markdown(_), do: ""

  # --- Thought history helpers ---

  defp inspector_thought_badge_class(:thinking),
    do: "text-[9px] font-medium text-violet-400/70 uppercase tracking-wider"

  defp inspector_thought_badge_class(:message),
    do: "text-[9px] font-medium text-emerald-400/70 uppercase tracking-wider"

  defp inspector_thought_badge_class(_),
    do: "text-[9px] font-medium text-muted/50 uppercase tracking-wider"

  defp inspector_thought_label(:thinking), do: "Thought"
  defp inspector_thought_label(:message), do: "Response"
  defp inspector_thought_label(type), do: to_string(type)

  defp format_inspector_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_inspector_time(_), do: ""
end
