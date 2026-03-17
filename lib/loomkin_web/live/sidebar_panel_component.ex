defmodule LoomkinWeb.SidebarPanelComponent do
  @moduledoc """
  LiveComponent for the sidebar tab panel (Files, Diff, Graph, Context).

  Renders the outer sidebar container, tab bar, and tab content.
  All state is passed as assigns from the parent. Tab events and file
  deselect are forwarded to the parent via send(self(), {:sidebar_event, ...}).
  """

  use LoomkinWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:graph_sub_tab, fn -> :tasks end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[20rem] w-full flex flex-col xl:h-auto xl:w-80 bg-surface-1 border-t border-subtle">
      <%!-- Sidebar tab bar --%>
      <div
        role="tablist"
        aria-label="Inspector tabs"
        class="flex items-center gap-0.5 px-1.5 py-1 overflow-x-auto flex-shrink-0 border-b border-subtle"
      >
        <button
          :for={tab <- [:files, :diff, :graph, :context]}
          role="tab"
          aria-selected={to_string(@active_tab == tab)}
          aria-controls={"tab-panel-#{tab}"}
          id={"tab-#{tab}"}
          phx-click="switch_tab"
          phx-value-tab={tab}
          phx-target={@myself}
          class={"relative flex items-center gap-1 px-2 py-1.5 text-[11px] font-medium rounded-md transition-all duration-200 interactive " <>
            if(@active_tab == tab,
              do: "text-brand after:absolute after:bottom-0 after:left-1 after:right-1 after:h-[1.5px] after:rounded-full after:bg-violet-500",
              else: "text-muted")}
        >
          <span aria-hidden="true">{tab_icon(tab)}</span>
          <span class="text-[10px]">{tab_label(tab)}</span>
        </button>
      </div>

      <%!-- Sidebar content --%>
      <div
        role="tabpanel"
        id={"tab-panel-#{@active_tab}"}
        aria-labelledby={"tab-#{@active_tab}"}
        tabindex="0"
        class={[
          "flex-1 overflow-auto tab-content-enter bg-surface-0",
          @active_tab != :context && "p-3"
        ]}
        phx-hook="TabTransition"
      >
        {render_tab(@active_tab, assigns)}
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    send(self(), {:sidebar_event, "switch_tab", %{"tab" => tab}})
    {:noreply, socket}
  end

  def handle_event("graph_sub_tab", %{"tab" => tab}, socket) do
    sub_tab = String.to_existing_atom(tab)
    {:noreply, assign(socket, graph_sub_tab: sub_tab)}
  end

  def handle_event("deselect_file", _params, socket) do
    send(self(), {:sidebar_event, "deselect_file", %{}})
    {:noreply, socket}
  end

  def handle_event("edit_explorer_path", params, socket) do
    send(self(), {:sidebar_event, "edit_explorer_path", params})
    {:noreply, socket}
  end

  def handle_event("cancel_edit_explorer", params, socket) do
    send(self(), {:sidebar_event, "cancel_edit_explorer", params})
    {:noreply, socket}
  end

  def handle_event("set_explorer_path", params, socket) do
    send(self(), {:sidebar_event, "set_explorer_path", params})
    {:noreply, socket}
  end

  # --- Tab helpers ---

  defp tab_icon(:files),
    do: raw("<span class=\"hero-folder-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:diff),
    do: raw("<span class=\"hero-code-bracket-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:graph),
    do: raw("<span class=\"hero-share-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:context),
    do: raw("<span class=\"hero-circle-stack-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_label(:files), do: "Files"
  defp tab_label(:diff), do: "Diff"
  defp tab_label(:graph), do: "Graph"
  defp tab_label(:context), do: "Context"

  defp render_tab(:files, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class={if @selected_file, do: "h-1/2 overflow-auto", else: "flex-1"}>
        <.live_component
          module={LoomkinWeb.FileTreeComponent}
          id="file-tree"
          project_path={assigns[:explorer_path] || assigns[:project_path] || File.cwd!()}
          session_id={@session_id}
          version={@file_tree_version}
        />
      </div>
      <div :if={@selected_file} class="h-1/2 border-t border-gray-800 flex flex-col animate-fade-in">
        <div class="flex items-center justify-between px-3 py-2 bg-gray-900/80 border-b border-gray-800">
          <div class="flex items-center gap-2 truncate">
            <.icon name="hero-document-text-mini" class="w-3.5 h-3.5 text-violet-400 flex-shrink-0" />
            <span class="text-xs text-violet-400 font-mono truncate">{@selected_file}</span>
          </div>
          <button
            phx-click="deselect_file"
            phx-target={@myself}
            class="text-gray-500 hover:text-gray-300 text-xs p-1 rounded hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
          </button>
        </div>
        <div
          id={"file-preview-#{@selected_file}"}
          phx-hook="SyntaxHighlight"
          class="flex-1 overflow-auto file-preview-container"
        >
          <pre class="file-preview-pre"><code class={"language-#{language_from_path(@selected_file)}"}>{@file_content}</code></pre>
        </div>
      </div>
    </div>
    """
  end

  defp render_tab(:diff, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DiffComponent}
      id="diff-viewer"
      diffs={@diffs}
    />
    """
  end

  defp render_tab(:graph, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-1 px-2 py-1.5 border-b border-subtle flex-shrink-0">
        <button
          :for={sub <- [:tasks, :decisions]}
          phx-click="graph_sub_tab"
          phx-value-tab={sub}
          phx-target={@myself}
          class={"px-2 py-1 text-[10px] font-medium rounded transition-colors duration-150 " <>
            if(@graph_sub_tab == sub,
              do: "text-brand bg-brand/10",
              else: "text-muted hover:text-gray-300")}
        >
          {graph_sub_tab_label(sub)}
        </button>
      </div>
      <div class="flex-1 overflow-auto">
        {render_graph_sub_tab(@graph_sub_tab, assigns)}
      </div>
    </div>
    """
  end

  defp render_tab(:context, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.ContextLibraryComponent}
      id="context-library"
      team_id={@active_team_id}
    />
    """
  end

  defp graph_sub_tab_label(:tasks), do: "Tasks"
  defp graph_sub_tab_label(:decisions), do: "Decisions"

  defp render_graph_sub_tab(:tasks, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.TaskGraphComponent}
      id="task-graph"
      session_id={@session_id}
      team_id={@active_team_id}
    />
    """
  end

  defp render_graph_sub_tab(:decisions, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DecisionGraphComponent}
      id="decision-graph"
      session_id={@session_id}
      team_id={@active_team_id}
    />
    """
  end

  # --- Language helper ---

  defp language_from_path(nil), do: "plaintext"

  defp language_from_path(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ".js" -> "javascript"
      ".json" -> "json"
      ext when ext in [".sh", ".bash", ".zsh"] -> "bash"
      ".css" -> "css"
      ext when ext in [".html", ".heex", ".leex"] -> "html"
      ".xml" -> "xml"
      ".md" -> "markdown"
      ext when ext in [".yml", ".yaml"] -> "yaml"
      ".diff" -> "diff"
      ".toml" -> "elixir"
      _ -> "plaintext"
    end
  end
end
