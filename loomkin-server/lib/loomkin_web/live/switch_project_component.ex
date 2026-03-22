defmodule LoomkinWeb.SwitchProjectComponent do
  @moduledoc """
  Modal component for switching the active project directory.

  Two-phase UX:
    1. Path input (pre-filled with current explorer_path)
    2. Confirmation with active agent list (only when agents are running)
  """
  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:fp_open, fn -> false end)
     |> assign_new(:fp_dir, fn -> nil end)
     |> assign_new(:fp_entries, fn -> [] end)
     |> assign_new(:fp_selected, fn -> nil end)}
  end

  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 animate-fade-in"
      aria-hidden="true"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="switch-project-title"
        aria-hidden="false"
        class="bg-gray-900 border border-gray-700/50 rounded-2xl shadow-2xl p-6 max-w-lg w-full mx-4 animate-scale-in"
      >
        <%= case @modal.phase do %>
          <% :input -> %>
            {render_input_phase(assigns)}
          <% :confirm -> %>
            {render_confirm_phase(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_input_phase(assigns) do
    ~H"""
    <%!-- Header --%>
    <div class="flex items-center gap-3 mb-4">
      <div class="w-10 h-10 rounded-xl bg-violet-500/10 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-folder-arrow-down" class="w-5 h-5 text-violet-400" />
      </div>
      <div>
        <h3 id="switch-project-title" class="text-sm font-semibold text-gray-100">Switch Project</h3>
        <p class="text-[10px] text-gray-500 mt-0.5">Change the working directory for all agents</p>
      </div>
    </div>

    <%!-- Recent projects --%>
    <div :if={@recent_projects != []} class="mb-3">
      <p class="text-[10px] text-gray-500 uppercase tracking-wider mb-1.5">Recent</p>
      <div class="flex flex-col gap-1">
        <div :for={rp <- @recent_projects} class="flex items-center gap-1.5">
          <button
            phx-click="switch_project_set_path"
            phx-value-path={rp}
            phx-target={@myself}
            class="flex-1 flex items-center gap-2 text-left px-3 py-1.5 rounded-lg text-xs font-mono text-gray-300 bg-gray-800/40 hover:bg-gray-800 transition truncate min-w-0"
            title={"Switch to #{rp}"}
          >
            <.icon name="hero-clock-mini" class="w-3 h-3 text-gray-500 flex-shrink-0" />
            <span class="truncate">{rp}</span>
          </button>
          <button
            phx-click="new_session_for_project"
            phx-value-path={rp}
            phx-target={@myself}
            class="flex-shrink-0 flex items-center gap-1 px-2 py-1.5 rounded-lg text-[10px] font-medium text-violet-400 bg-violet-500/10 hover:bg-violet-500/20 transition"
            title={"New session in #{Path.basename(rp)}"}
          >
            <.icon name="hero-plus-mini" class="w-3 h-3" /> New
          </button>
        </div>
      </div>
    </div>

    <%!-- Path input --%>
    <form phx-submit="switch_project_set_path" phx-target={@myself} class="space-y-4">
      <div>
        <label class="text-[10px] text-gray-500 uppercase tracking-wider">Project directory</label>
        <div class="relative mt-1">
          <input
            type="text"
            name="path"
            value={@fp_selected || @modal.target_path || @explorer_path}
            class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 pr-10 text-sm text-gray-200 font-mono focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-500/50"
            autofocus
            placeholder="/path/to/project"
          />
          <button
            type="button"
            phx-click="fp_open"
            phx-target={@myself}
            class="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300 transition-colors"
            tabindex="-1"
            title="Browse folders"
          >
            <.icon name="hero-folder-mini" class="w-4 h-4" />
          </button>
          <div :if={@fp_open} class="absolute top-full mt-1 left-0 right-0 z-50">
            <div class="fixed inset-0 z-40" phx-click="fp_close" phx-target={@myself} />
            <div class="relative z-50 bg-gray-900 border border-gray-700/60 rounded-xl shadow-2xl overflow-hidden">
              <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-700/50 bg-gray-800/60">
                <button
                  type="button"
                  phx-click="fp_up"
                  phx-target={@myself}
                  class="text-gray-400 hover:text-gray-200 transition-colors p-0.5 rounded"
                >
                  <.icon name="hero-arrow-left-mini" class="w-3.5 h-3.5" />
                </button>
                <span class="text-xs text-gray-400 font-mono truncate flex-1">{@fp_dir}</span>
                <button
                  type="button"
                  phx-click="fp_close"
                  phx-target={@myself}
                  class="text-gray-500 hover:text-gray-300 transition-colors p-0.5 rounded"
                >
                  <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
                </button>
              </div>
              <div class="max-h-52 overflow-y-auto py-1">
                <p
                  :if={@fp_entries == []}
                  class="px-3 py-3 text-xs text-gray-500 italic text-center"
                >
                  No subdirectories
                </p>
                <button
                  :for={entry <- @fp_entries}
                  type="button"
                  phx-click="fp_navigate"
                  phx-value-dir={Path.join(@fp_dir, entry)}
                  phx-target={@myself}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800 transition-colors"
                >
                  <.icon name="hero-folder-mini" class="w-3.5 h-3.5 text-gray-500 flex-shrink-0" />
                  {entry}
                </button>
              </div>
              <div class="border-t border-gray-700/50 px-3 py-2">
                <button
                  type="button"
                  phx-click="fp_select"
                  phx-target={@myself}
                  class="w-full text-xs text-center text-violet-400 hover:text-violet-300 font-medium py-1 rounded-lg hover:bg-violet-500/10 transition-colors"
                >
                  Select this folder
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
      <div class="flex gap-2 justify-end">
        <button
          type="button"
          phx-click="cancel_switch_project"
          phx-target={@myself}
          class="px-4 py-2 text-xs font-medium text-gray-400 bg-gray-800/60 hover:bg-gray-800 hover:text-gray-300 border border-gray-700/50 rounded-xl transition-all duration-200"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="px-4 py-2 text-xs font-medium text-white bg-violet-600 hover:bg-violet-500 rounded-xl transition-all duration-200 shadow-lg shadow-violet-500/20"
        >
          Continue
        </button>
      </div>
    </form>
    """
  end

  defp render_confirm_phase(assigns) do
    ~H"""
    <%!-- Header --%>
    <div class="flex items-center gap-3 mb-4">
      <div class="w-10 h-10 rounded-xl bg-amber-500/10 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-amber-400" />
      </div>
      <div>
        <h3 class="text-sm font-semibold text-gray-100">Active Agents Detected</h3>
        <p class="text-[10px] text-gray-500 mt-0.5">
          Switching will stop all running agents in the current project
        </p>
      </div>
    </div>

    <%!-- Target path --%>
    <div class="mb-4 px-3 py-2 bg-gray-800/60 rounded-lg border border-gray-700/30">
      <span class="text-[10px] text-gray-500 uppercase tracking-wider">New project</span>
      <p class="text-sm font-mono text-violet-400 mt-0.5 truncate">{@modal.target_path}</p>
    </div>

    <%!-- Active agents list --%>
    <div class="mb-5">
      <p class="text-[10px] text-gray-500 uppercase tracking-wider mb-2">
        Active agents ({length(@modal.active_agents)})
      </p>
      <div class="max-h-40 overflow-auto space-y-1">
        <div
          :for={agent <- @modal.active_agents}
          class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/40 rounded-lg"
        >
          <span class="w-2 h-2 rounded-full bg-violet-400 animate-pulse flex-shrink-0"></span>
          <span class="text-xs text-gray-200 font-medium">{agent.name}</span>
          <span class="text-[10px] text-gray-500">{agent.role}</span>
          <span class={"ml-auto text-[10px] " <> agent_status_class(agent.status)}>
            {agent.status}
          </span>
        </div>
      </div>
    </div>

    <%!-- Action buttons --%>
    <div class="flex gap-2 justify-end">
      <button
        phx-click="cancel_switch_project"
        phx-target={@myself}
        class="px-4 py-2 text-xs font-medium text-gray-400 bg-gray-800/60 hover:bg-gray-800 hover:text-gray-300 border border-gray-700/50 rounded-xl transition-all duration-200"
      >
        Cancel
      </button>
      <button
        phx-click="confirm_switch_project"
        phx-target={@myself}
        class="px-4 py-2 text-xs font-medium text-white bg-amber-600 hover:bg-amber-500 rounded-xl transition-all duration-200 shadow-lg shadow-amber-500/20"
      >
        Stop Agents & Switch
      </button>
    </div>
    """
  end

  # Events

  def handle_event("fp_open", _params, socket) do
    current =
      socket.assigns.fp_selected ||
        socket.assigns.modal.target_path ||
        socket.assigns.explorer_path

    expanded = Path.expand(current || "")

    dir =
      if expanded != "" and expanded != File.cwd!() and File.dir?(expanded) do
        expanded
      else
        System.user_home!()
      end

    {:noreply, assign(socket, fp_open: true, fp_dir: dir, fp_entries: list_subdirs(dir))}
  end

  def handle_event("fp_close", _params, socket) do
    {:noreply, assign(socket, fp_open: false)}
  end

  def handle_event("fp_navigate", %{"dir" => dir}, socket) do
    {:noreply, assign(socket, fp_dir: dir, fp_entries: list_subdirs(dir))}
  end

  def handle_event("fp_up", _params, socket) do
    parent = Path.dirname(socket.assigns.fp_dir)

    if parent != socket.assigns.fp_dir do
      {:noreply, assign(socket, fp_dir: parent, fp_entries: list_subdirs(parent))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("fp_select", _params, socket) do
    {:noreply, assign(socket, fp_selected: socket.assigns.fp_dir, fp_open: false)}
  end

  def handle_event("switch_project_set_path", %{"path" => path}, socket) do
    expanded = path |> String.trim() |> Path.expand()
    send(self(), {:switch_project_set_path, expanded})
    {:noreply, socket}
  end

  def handle_event("new_session_for_project", %{"path" => path}, socket) do
    send(self(), {:new_session_for_project, path})
    {:noreply, socket}
  end

  def handle_event("cancel_switch_project", _params, socket) do
    send(self(), :cancel_switch_project)
    {:noreply, socket}
  end

  def handle_event("confirm_switch_project", _params, socket) do
    send(self(), :confirm_switch_project)
    {:noreply, socket}
  end

  defp list_subdirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(path, &1)))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp agent_status_class(:idle), do: "text-green-400"
  defp agent_status_class(:working), do: "text-violet-400"
  defp agent_status_class(:thinking), do: "text-violet-400"
  defp agent_status_class(_), do: "text-gray-400"
end
