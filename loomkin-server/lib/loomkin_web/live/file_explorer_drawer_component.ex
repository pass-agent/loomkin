defmodule LoomkinWeb.FileExplorerDrawerComponent do
  @moduledoc """
  Slide-out drawer for file explorer and diffs.

  Overlays from the right edge, independent from the agent focus panel.
  Toggled via a button in the header or keyboard shortcut.
  """

  use LoomkinWeb, :live_component

  @tabs [:files, :diff]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, active_tab: :files, open: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @valid_tabs ~w(files diff)

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @valid_tabs do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("close", _params, socket) do
    send(self(), :close_file_drawer)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div
      id="file-explorer-drawer"
      class={if @open, do: "fixed inset-0 z-[60] flex justify-end", else: "hidden"}
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/40 animate-fade-in"
        aria-hidden="true"
        phx-click="close"
        phx-target={@myself}
      />

      <%!-- Drawer panel --%>
      <div
        role="dialog"
        aria-modal="true"
        aria-label="File explorer"
        class="relative w-full max-w-md h-full flex flex-col bg-surface-1 border-l border-subtle shadow-2xl drawer-slide-in"
      >
        <%!-- Header --%>
        <div class="flex items-center gap-2 px-3 py-2 flex-shrink-0 border-b border-subtle bg-surface-1">
          <.icon name="hero-folder-open-mini" class="w-4 h-4 text-brand" />
          <span class="text-xs font-semibold text-secondary">Explorer</span>

          <div class="flex-1" />

          <%!-- Tab buttons --%>
          <div class="flex items-center gap-0.5">
            <button
              :for={tab <- @tabs}
              phx-click="switch_tab"
              phx-value-tab={tab}
              phx-target={@myself}
              class={tab_class(@active_tab, tab)}
            >
              {tab_icon(tab)}
              <span class="text-[10px]">{tab_label(tab)}</span>
            </button>
          </div>

          <button
            phx-click="close"
            phx-target={@myself}
            class="interactive p-1 rounded-md text-muted hover:text-secondary"
            data-tooltip="Close (Esc)"
            aria-label="Close (Esc)"
          >
            <.icon name="hero-x-mark-mini" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-auto min-h-0 bg-surface-0">
          <div class="tab-content-enter h-full">
            {render_tab(@active_tab, assigns)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Tab content ─────────────────────────────────────────────────────

  defp render_tab(:files, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class={if @selected_file, do: "h-1/2 overflow-auto", else: "flex-1"}>
        <.live_component
          module={LoomkinWeb.FileTreeComponent}
          id="drawer-files"
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

  defp render_tab(:diff, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DiffComponent}
      id="drawer-diff"
      diffs={@diffs}
    />
    """
  end

  # ── Styling helpers ─────────────────────────────────────────────────

  defp tab_class(active, tab) do
    base =
      "flex items-center gap-1 px-2 py-1 text-[11px] font-medium rounded-md transition-all duration-200 interactive "

    if active == tab do
      base <> "text-brand bg-white/[0.04]"
    else
      base <> "text-muted"
    end
  end

  defp tab_icon(:files),
    do: raw("<span class=\"hero-folder-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:diff),
    do: raw("<span class=\"hero-code-bracket-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_label(:files), do: "Files"
  defp tab_label(:diff), do: "Diff"
end
