defmodule LoomkinWeb.ContextInspectorComponent do
  @moduledoc """
  Right-panel context inspector for Mission Control mode.

  Hosts existing components (FileTree, Diff, Terminal, Graph) in a tabbed
  layout with auto-follow and pin modes. Delegates all rendering to the child
  components — does not rebuild any of them.
  """

  use LoomkinWeb, :live_component

  @tabs [:files, :diff, :terminal, :graph]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, collapsed: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @valid_inspector_tabs ~w(files diff terminal graph)
  @impl true
  def handle_event("switch_inspector_tab", %{"tab" => tab}, socket)
      when tab in @valid_inspector_tabs do
    send(self(), {:inspector_tab, String.to_existing_atom(tab)})
    {:noreply, socket}
  end

  def handle_event("resume_follow", _params, socket) do
    send(self(), {:resume_follow})
    {:noreply, socket}
  end

  def handle_event("toggle_collapse", _params, socket) do
    {:noreply, assign(socket, collapsed: !socket.assigns.collapsed)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div id="inspector-panel" class={panel_class(@collapsed)} phx-hook="ResizablePanel">
      <%!-- Drag handle (left edge) --%>
      <div
        :if={!@collapsed}
        id="inspector-resize-handle"
        class="hidden xl:flex absolute left-0 top-0 bottom-0 w-1 cursor-col-resize z-10 items-center justify-center group hover:bg-violet-500/20 active:bg-violet-500/30 transition-[background] duration-150"
      >
        <div class="w-0.5 h-8 rounded-full bg-zinc-600 group-hover:bg-violet-400 group-active:bg-violet-400 transition-[background] duration-150">
        </div>
      </div>
      <%= if @collapsed do %>
        <.collapsed_strip
          tabs={@tabs}
          active_inspector_tab={@active_inspector_tab}
          myself={@myself}
        />
      <% else %>
        <%!-- Tab bar --%>
        <div class="flex items-center gap-0.5 overflow-x-auto px-1.5 py-1 flex-shrink-0 bg-surface-1 border-b border-subtle">
          <button
            :for={tab <- @tabs}
            phx-click="switch_inspector_tab"
            phx-value-tab={tab}
            phx-target={@myself}
            class={tab_button_class(@active_inspector_tab, tab)}
          >
            <span>{tab_icon(tab)}</span>
            <span class="text-[10px]">{tab_label(tab)}</span>
          </button>

          <div class="ml-auto flex items-center gap-1.5 pl-1.5">
            <.follow_indicator
              inspector_mode={@inspector_mode}
              focused_agent={@focused_agent}
              myself={@myself}
            />
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

        <%!-- Content area --%>
        <div
          id="inspector-content"
          class="flex-1 overflow-auto min-h-0 relative bg-surface-0"
          phx-update="ignore"
        >
          <%!-- Decision graph is always mounted (stays subscribed to PubSub) --%>
          <div class={if @active_inspector_tab == :graph, do: "h-full", else: "hidden"}>
            <.live_component
              module={LoomkinWeb.DecisionGraphComponent}
              id="inspector-graph"
              session_id={@session_id}
              team_id={@team_id}
            />
          </div>
          <%!-- Other tabs render on demand --%>
          <div :if={@active_inspector_tab != :graph} class="tab-content-enter h-full">
            {render_inspector_tab(@active_inspector_tab, assigns)}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Collapsed strip (icon-only sidebar) ---

  defp collapsed_strip(assigns) do
    ~H"""
    <div class="flex h-full w-full items-center justify-center gap-0.5 px-1 py-1 xl:flex-col xl:items-center xl:justify-start xl:px-0 xl:py-1.5 bg-surface-1">
      <button
        :for={tab <- @tabs}
        phx-click="switch_inspector_tab"
        phx-value-tab={tab}
        phx-target={@myself}
        class={collapsed_tab_class(@active_inspector_tab, tab)}
        title={tab_label(tab)}
      >
        <span>{tab_icon(tab)}</span>
      </button>

      <div class="xl:mt-auto xl:mb-1">
        <button
          phx-click="toggle_collapse"
          phx-target={@myself}
          class="interactive p-1 rounded-md text-muted"
          title="Expand panel"
        >
          <.icon name="hero-chevron-left-mini" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # --- Follow mode indicator ---

  defp follow_indicator(%{focused_agent: nil} = assigns), do: ~H""

  defp follow_indicator(%{inspector_mode: :auto_follow} = assigns) do
    ~H"""
    <div class="badge-success gap-1.5">
      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse flex-shrink-0"></span>
      <span class="truncate max-w-[100px]">Following {@focused_agent}</span>
    </div>
    """
  end

  defp follow_indicator(%{inspector_mode: :pinned} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <div class="badge gap-1.5">
        <.icon name="hero-map-pin-mini" class="w-3 h-3 flex-shrink-0" />
        <span class="truncate max-w-[100px]">Pinned to {@focused_agent}</span>
      </div>
      <button
        phx-click="resume_follow"
        phx-target={@myself}
        class="press-down text-[10px] px-2 py-0.5 rounded-full font-medium bg-brand-subtle text-brand border border-brand"
      >
        Resume
      </button>
    </div>
    """
  end

  defp follow_indicator(assigns), do: ~H""

  # --- Tab content delegation ---

  defp render_inspector_tab(:files, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class={if @selected_file, do: "h-1/2 overflow-auto", else: "flex-1"}>
        <.live_component
          module={LoomkinWeb.FileTreeComponent}
          id="inspector-files"
          project_path={@project_path}
          version={@file_tree_version}
          selected={@selected_file}
        />
      </div>
      <div
        :if={@selected_file}
        class="h-1/2 flex flex-col animate-fade-in-up border-t border-subtle"
      >
        <div class="flex items-center justify-between px-3 py-2 bg-surface-2 flex-shrink-0 border-b border-subtle">
          <div class="flex items-center gap-2 truncate">
            <.icon name="hero-document-text-mini" class="w-3.5 h-3.5 text-brand flex-shrink-0" />
            <span class="text-xs text-brand font-mono truncate">{@selected_file}</span>
          </div>
        </div>
        <pre class="flex-1 overflow-auto p-3 text-xs font-mono text-secondary whitespace-pre bg-surface-0">{@file_content}</pre>
      </div>
    </div>
    """
  end

  defp render_inspector_tab(:diff, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DiffComponent}
      id="inspector-diff"
      diffs={@diffs}
    />
    """
  end

  defp render_inspector_tab(:terminal, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.TerminalComponent}
      id="inspector-terminal"
      commands={@shell_commands}
    />
    """
  end

  # :graph tab is always-mounted above — no render_inspector_tab clause needed

  # --- Styling helpers ---

  defp panel_class(true = _collapsed),
    do:
      "inspector-panel inspector-collapsed w-full h-10 xl:w-9 xl:h-full flex flex-col bg-surface-1 transition-all duration-300 ease-in-out"

  defp panel_class(false = _collapsed),
    do:
      "inspector-panel relative w-full h-[20rem] xl:w-80 xl:h-full flex-shrink-0 flex flex-col bg-surface-1 transition-colors duration-300 ease-in-out"

  defp tab_button_class(active, tab) do
    base =
      "relative flex shrink-0 items-center gap-1 whitespace-nowrap px-2 py-1.5 text-[11px] font-medium rounded-md transition-all duration-200 interactive "

    if active == tab do
      (base <>
         "after:absolute after:bottom-0 after:left-1 after:right-1 after:h-[1.5px] after:rounded-full")
      |> Kernel.<>(" ")
      |> Kernel.<>("text-brand after:bg-violet-500")
    else
      base <> "text-muted"
    end
  end

  defp collapsed_tab_class(active, tab) do
    base = "p-1.5 rounded-md transition-all duration-200 interactive "

    if active == tab do
      base <> "text-brand bg-white/[0.04]"
    else
      base <> "text-muted"
    end
  end

  defp tab_icon(:files),
    do: raw("<span class=\"hero-folder-mini inline-block w-4 h-4\"></span>")

  defp tab_icon(:diff),
    do: raw("<span class=\"hero-code-bracket-mini inline-block w-4 h-4\"></span>")

  defp tab_icon(:terminal),
    do: raw("<span class=\"hero-command-line-mini inline-block w-4 h-4\"></span>")

  defp tab_icon(:graph),
    do: raw("<span class=\"hero-share-mini inline-block w-4 h-4\"></span>")

  defp tab_label(:files), do: "Files"
  defp tab_label(:diff), do: "Diff"
  defp tab_label(:terminal), do: "Terminal"
  defp tab_label(:graph), do: "Graph"
end
