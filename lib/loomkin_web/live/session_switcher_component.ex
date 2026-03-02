defmodule LoomkinWeb.SessionSwitcherComponent do
  use LoomkinWeb, :live_component

  alias Loomkin.Session.Persistence

  def update(assigns, socket) do
    sessions = list_all_sessions()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(sessions: sessions, dropdown_open: false)}
  end

  def render(assigns) do
    ~H"""
    <div class="relative" id="session-switcher-wrapper" phx-click-away="close_dropdown" phx-target={@myself}>
      <%!-- Trigger button --%>
      <button
        phx-click="toggle_dropdown"
        phx-target={@myself}
        class="flex items-center gap-2 bg-gray-800/60 hover:bg-gray-800 border border-gray-700/50 rounded-lg px-3 py-1.5 text-xs text-gray-300 transition-all duration-200 max-w-[200px]"
      >
        <.icon name="hero-clock-mini" class="w-3.5 h-3.5 text-gray-500 flex-shrink-0" />
        <span class="truncate">{current_session_label(@session_id, @sessions)}</span>
        <svg class={"w-3 h-3 text-gray-500 flex-shrink-0 transition-transform duration-200 " <> if(@dropdown_open, do: "rotate-180", else: "")} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Dropdown --%>
      <div
        :if={@dropdown_open}
        class="absolute right-0 top-full mt-1 w-64 bg-gray-900 border border-gray-700/50 rounded-xl shadow-2xl z-30 overflow-hidden animate-scale-in"
      >
        <%!-- New session option --%>
        <button
          phx-click="new_session"
          phx-target={@myself}
          class="w-full flex items-center gap-2 px-4 py-2.5 text-xs text-violet-400 hover:bg-violet-500/10 transition-colors border-b border-gray-800"
        >
          <.icon name="hero-plus-mini" class="w-3.5 h-3.5" />
          <span class="font-medium">New Session</span>
        </button>

        <%!-- Session list --%>
        <div class="max-h-48 overflow-y-auto py-1">
          <button
            :for={session <- @sessions}
            phx-click="select_session"
            phx-value-id={session.id}
            phx-target={@myself}
            class={"w-full flex items-center gap-2 px-4 py-2 text-xs transition-colors " <>
              if(session.id == @session_id,
                do: "bg-violet-500/10 text-violet-400",
                else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-300")}
          >
            <span :if={session.id == @session_id} class="flex-shrink-0">
              <.icon name="hero-check-mini" class="w-3.5 h-3.5 text-violet-400" />
            </span>
            <span :if={session.id != @session_id} class="w-3.5 flex-shrink-0" />
            <span class="truncate flex-1 text-left">{session_label(session)}</span>
            <span class="text-[10px] text-gray-600 flex-shrink-0">{relative_time(session)}</span>
          </button>
        </div>

        <div :if={@sessions == []} class="px-4 py-3 text-xs text-gray-600 text-center">
          No previous sessions
        </div>
      </div>
    </div>
    """
  end

  def handle_event("toggle_dropdown", _params, socket) do
    {:noreply, assign(socket, dropdown_open: !socket.assigns.dropdown_open)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, dropdown_open: false)}
  end

  def handle_event("new_session", _params, socket) do
    send(self(), :new_session)
    {:noreply, assign(socket, dropdown_open: false)}
  end

  def handle_event("select_session", %{"id" => session_id}, socket) do
    send(self(), {:select_session, session_id})
    {:noreply, assign(socket, dropdown_open: false)}
  end

  defp list_all_sessions do
    Persistence.list_sessions()
  end

  defp current_session_label(session_id, sessions) do
    case Enum.find(sessions, &(&1.id == session_id)) do
      nil -> "Session #{String.slice(session_id, 0, 8)}"
      session -> session_label(session)
    end
  end

  defp session_label(session) do
    title = session.title || "Untitled"

    if String.length(title) > 24 do
      String.slice(title, 0, 24) <> "..."
    else
      title
    end
  end

  defp relative_time(session) do
    case Map.get(session, :updated_at) || Map.get(session, :inserted_at) do
      nil ->
        ""

      datetime ->
        diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

        cond do
          diff < 60 -> "now"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86400)}d ago"
        end
    end
  rescue
    _ -> ""
  end
end
