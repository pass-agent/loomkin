defmodule LoomkinWeb.PermissionComponent do
  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
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
        aria-labelledby="permission-dialog-title"
        aria-hidden="false"
        class="bg-gray-900 border border-gray-700/50 rounded-2xl shadow-2xl p-6 max-w-md w-full mx-4 animate-scale-in"
      >
        <%!-- Header --%>
        <div class="flex items-center gap-3 mb-4">
          <div class="w-10 h-10 rounded-xl bg-violet-500/10 flex items-center justify-center flex-shrink-0">
            <.icon name="hero-shield-check" class="w-5 h-5 text-violet-400" />
          </div>
          <div>
            <h3 id="permission-dialog-title" class="text-sm font-semibold text-gray-100">
              Permission Required
            </h3>
            <p class="text-[10px] text-gray-500 mt-0.5">
              Review this tool execution before proceeding
            </p>
          </div>
        </div>

        <%!-- Tool info --%>
        <div class="space-y-3 mb-5">
          <div class="flex items-center gap-2">
            <span class="text-[10px] text-gray-500 uppercase tracking-wider">Tool</span>
            <span class="inline-flex items-center gap-1.5 bg-violet-500/10 border border-violet-500/20 rounded-full px-3 py-1 text-xs font-mono text-violet-400">
              <.icon name="hero-wrench-screwdriver-mini" class="w-3 h-3" />
              {@tool_name}
            </span>
          </div>
          <div class="flex items-start gap-2">
            <span class="text-[10px] text-gray-500 uppercase tracking-wider mt-0.5">Path</span>
            <div class="flex items-center gap-1.5 min-w-0">
              <.icon name="hero-document-text-mini" class="w-3.5 h-3.5 text-gray-500 flex-shrink-0" />
              <span class="text-xs font-mono text-gray-300 break-all">{@tool_path}</span>
            </div>
          </div>
        </div>

        <%!-- Action buttons --%>
        <div class="flex gap-2 justify-end">
          <button
            phx-click="permission_response"
            phx-value-action="deny"
            phx-target={@myself}
            class="px-4 py-2 text-xs font-medium text-gray-400 bg-gray-800/60 hover:bg-gray-800 hover:text-gray-300 border border-gray-700/50 rounded-xl transition-all duration-200"
          >
            Deny
          </button>
          <button
            phx-click="permission_response"
            phx-value-action="allow_once"
            phx-target={@myself}
            class="px-4 py-2 text-xs font-medium text-violet-400 bg-violet-500/10 hover:bg-violet-500/20 border border-violet-500/30 rounded-xl transition-all duration-200"
          >
            Allow Once
          </button>
          <button
            phx-click="permission_response"
            phx-value-action="allow_always"
            phx-target={@myself}
            class="px-4 py-2 text-xs font-medium text-white bg-violet-600 hover:bg-violet-500 rounded-xl transition-all duration-200 shadow-lg shadow-violet-500/20"
          >
            Allow Always
          </button>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("permission_response", %{"action" => action}, socket) do
    send(
      self(),
      {:permission_response, action, socket.assigns.tool_name, socket.assigns.tool_path}
    )

    {:noreply, socket}
  end
end
