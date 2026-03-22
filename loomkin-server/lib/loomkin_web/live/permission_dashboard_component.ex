defmodule LoomkinWeb.PermissionDashboardComponent do
  @moduledoc """
  Persistent approval panel replacing the single-slot permission modal.

  Shows all pending permission requests with individual and batch actions.
  Renders as a slide-up panel at the bottom of the workspace.
  """

  use LoomkinWeb, :live_component

  import LoomkinWeb.TimeHelpers, only: [relative_time: 1]

  def update(assigns, socket) do
    pending = assigns.pending_permissions || []
    prev_pending = socket.assigns[:pending_permissions]

    socket = assign(socket, assigns)

    if pending != prev_pending do
      sorted =
        pending
        |> Enum.sort_by(fn req ->
          # Pin :execute to top, then sort newest first
          priority = if req.category == :execute, do: 0, else: 1
          {priority, DateTime.to_unix(req.requested_at) * -1}
        end)

      unique_agents =
        pending
        |> Enum.map(& &1.agent_name)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "session"))

      {:ok, assign(socket, sorted_permissions: sorted, unique_agents: unique_agents)}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div
      id="permission-dashboard"
      class="fixed bottom-0 inset-x-0 z-50 animate-slide-up"
    >
      <%!-- Backdrop --%>
      <div class="absolute inset-0 -top-screen bg-black/30 pointer-events-none" />

      <div class="relative bg-gray-900/95 backdrop-blur-xl border-t border-gray-700/50 shadow-2xl shadow-black/50">
        <%!-- Header bar --%>
        <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-800/50">
          <div class="flex items-center gap-2.5">
            <div class="flex items-center justify-center w-7 h-7 rounded-lg bg-amber-500/10">
              <.icon name="hero-shield-check" class="w-4 h-4 text-amber-400" />
            </div>
            <h3 class="text-sm font-semibold text-gray-100">
              Pending Approvals
            </h3>
            <span class="inline-flex items-center justify-center min-w-[20px] h-5 px-1.5 rounded-full bg-amber-500/20 text-amber-400 text-[10px] font-bold">
              {length(@sorted_permissions)}
            </span>
          </div>

          <%!-- Batch actions --%>
          <div class="flex items-center gap-1.5">
            <button
              :if={Enum.any?(@sorted_permissions, &(&1.category == :read))}
              phx-click="permission_batch_action"
              phx-value-action="allow_once"
              phx-value-scope="all_reads"
              phx-target={@myself}
              class="px-2.5 py-1 text-[10px] font-medium text-emerald-400 bg-emerald-500/10 hover:bg-emerald-500/20 border border-emerald-500/20 rounded-lg transition-all"
            >
              Approve All Reads
            </button>
            <button
              :for={agent <- @unique_agents}
              phx-click="permission_batch_action"
              phx-value-action="allow_once"
              phx-value-scope={"agent:#{agent}"}
              phx-target={@myself}
              class="px-2.5 py-1 text-[10px] font-medium text-violet-400 bg-violet-500/10 hover:bg-violet-500/20 border border-violet-500/20 rounded-lg transition-all"
            >
              Approve {agent}
            </button>
            <button
              phx-click="permission_batch_action"
              phx-value-action="deny"
              phx-value-scope="all"
              phx-target={@myself}
              class="px-2.5 py-1 text-[10px] font-medium text-red-400 bg-red-500/10 hover:bg-red-500/20 border border-red-500/20 rounded-lg transition-all"
            >
              Deny All
            </button>
          </div>
        </div>

        <%!-- Request list --%>
        <div class="max-h-64 overflow-y-auto overscroll-contain">
          <div
            :for={req <- @sorted_permissions}
            id={"perm-#{req.id}"}
            class="flex items-center gap-3 px-4 py-2.5 border-b border-gray-800/30 hover:bg-gray-800/30 transition-colors group"
          >
            <%!-- Category indicator --%>
            <div class={[
              "w-1.5 h-8 rounded-full flex-shrink-0",
              category_color_bg(req.category)
            ]} />

            <%!-- Agent info --%>
            <div class="flex items-center gap-1.5 min-w-[100px]">
              <span class="text-xs font-medium text-gray-300 truncate">
                {req.agent_name}
              </span>
            </div>

            <%!-- Tool badge --%>
            <span class={[
              "inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[10px] font-mono border flex-shrink-0",
              category_badge_classes(req.category)
            ]}>
              <.icon name="hero-wrench-screwdriver-mini" class="w-3 h-3" />
              {req.tool_name}
            </span>

            <%!-- Path --%>
            <span
              class="text-xs font-mono text-gray-500 truncate flex-1 min-w-0"
              title={req.tool_path}
            >
              {truncate_path(req.tool_path)}
            </span>

            <%!-- Timestamp --%>
            <span class="text-[10px] text-gray-600 flex-shrink-0 tabular-nums">
              {relative_time(req.requested_at)}
            </span>

            <%!-- Action buttons --%>
            <div class="flex items-center gap-1 flex-shrink-0 opacity-60 group-hover:opacity-100 transition-opacity">
              <button
                phx-click="permission_response"
                phx-value-action="deny"
                phx-value-id={req.id}
                phx-target={@myself}
                class="px-2 py-1 text-[10px] font-medium text-gray-500 hover:text-red-400 hover:bg-red-500/10 rounded-md transition-all"
              >
                Deny
              </button>
              <button
                phx-click="permission_response"
                phx-value-action="allow_once"
                phx-value-id={req.id}
                phx-target={@myself}
                class="px-2 py-1 text-[10px] font-medium text-violet-400/70 hover:text-violet-400 hover:bg-violet-500/10 rounded-md transition-all"
              >
                Once
              </button>
              <button
                phx-click="permission_response"
                phx-value-action="allow_always"
                phx-value-id={req.id}
                phx-target={@myself}
                class="px-2.5 py-1 text-[10px] font-medium text-white bg-violet-600/80 hover:bg-violet-500 rounded-md transition-all shadow-sm"
              >
                Always
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("permission_response", %{"action" => action, "id" => id}, socket) do
    send(self(), {:permission_response, action, id})
    {:noreply, socket}
  end

  def handle_event("permission_batch_action", %{"action" => action, "scope" => scope}, socket) do
    send(self(), {:permission_batch_action, action, scope})
    {:noreply, socket}
  end

  # --- Helpers ---

  defp category_color_bg(:read), do: "bg-emerald-400"
  defp category_color_bg(:write), do: "bg-amber-400"
  defp category_color_bg(:execute), do: "bg-red-400"
  defp category_color_bg(:coordination), do: "bg-blue-400"
  defp category_color_bg(_), do: "bg-gray-400"

  defp category_badge_classes(:read),
    do: "text-emerald-400 bg-emerald-500/10 border-emerald-500/20"

  defp category_badge_classes(:write),
    do: "text-amber-400 bg-amber-500/10 border-amber-500/20"

  defp category_badge_classes(:execute),
    do: "text-red-400 bg-red-500/10 border-red-500/20"

  defp category_badge_classes(:coordination),
    do: "text-blue-400 bg-blue-500/10 border-blue-500/20"

  defp category_badge_classes(_),
    do: "text-gray-400 bg-gray-500/10 border-gray-500/20"

  defp truncate_path(nil), do: ""

  defp truncate_path(path) when byte_size(path) > 50 do
    "..." <> String.slice(path, -47, 47)
  end

  defp truncate_path(path), do: path
end
