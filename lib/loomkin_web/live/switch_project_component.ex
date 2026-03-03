defmodule LoomkinWeb.SwitchProjectComponent do
  @moduledoc """
  Modal component for switching the active project directory.

  Two-phase UX:
    1. Path input (pre-filled with current explorer_path)
    2. Confirmation with active agent list (only when agents are running)
  """
  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 animate-fade-in">
      <div class="bg-gray-900 border border-gray-700/50 rounded-2xl shadow-2xl p-6 max-w-lg w-full mx-4 animate-scale-in">
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
        <h3 class="text-sm font-semibold text-gray-100">Switch Project</h3>
        <p class="text-[10px] text-gray-500 mt-0.5">Change the working directory for all agents</p>
      </div>
    </div>

    <%!-- Recent projects --%>
    <div :if={@recent_projects != []} class="mb-3">
      <p class="text-[10px] text-gray-500 uppercase tracking-wider mb-1.5">Recent</p>
      <div class="flex flex-col gap-1">
        <button
          :for={rp <- @recent_projects}
          phx-click="switch_project_set_path"
          phx-value-path={rp}
          phx-target={@myself}
          class="flex items-center gap-2 text-left px-3 py-1.5 rounded-lg text-xs font-mono text-gray-300 bg-gray-800/40 hover:bg-gray-800 transition truncate"
        >
          <.icon name="hero-clock-mini" class="w-3 h-3 text-gray-500 flex-shrink-0" />
          {rp}
        </button>
      </div>
    </div>

    <%!-- Path input --%>
    <form phx-submit="switch_project_set_path" phx-target={@myself} class="space-y-4">
      <div>
        <label class="text-[10px] text-gray-500 uppercase tracking-wider">Project directory</label>
        <input
          type="text"
          name="path"
          value={@modal.target_path || @explorer_path}
          class="mt-1 w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 font-mono focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-500/50"
          autofocus
          placeholder="/path/to/project"
        />
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

  def handle_event("switch_project_set_path", %{"path" => path}, socket) do
    send(self(), {:switch_project_set_path, String.trim(path)})
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

  defp agent_status_class(:idle), do: "text-green-400"
  defp agent_status_class(:working), do: "text-violet-400"
  defp agent_status_class(:thinking), do: "text-violet-400"
  defp agent_status_class(_), do: "text-gray-400"
end
