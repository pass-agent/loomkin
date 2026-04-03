defmodule LoomkinWeb.SessionSwitcherComponent do
  use LoomkinWeb, :live_component

  require Logger

  alias Loomkin.Session.Persistence

  @impl true
  def update(assigns, socket) do
    prev_project_path = socket.assigns[:project_path]

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:dropdown_open, fn -> false end)
      |> assign_new(:sessions, fn -> :not_loaded end)

    project_path = socket.assigns[:project_path]

    if project_path != prev_project_path or socket.assigns.sessions == :not_loaded do
      sessions = Persistence.list_sessions(project_path: project_path)
      {:ok, assign(socket, sessions: sessions)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :session_index, current_session_index(assigns.session_id, assigns.sessions))

    ~H"""
    <div
      class="relative flex-shrink-0 border-b border-subtle bg-surface-0"
      id="session-switcher-wrapper"
      phx-click-away="close_dropdown"
      phx-target={@myself}
    >
      <%!-- Session bar — thin, muted, conversation-level --%>
      <div class="flex items-center gap-2 px-3 py-1">
        <button
          phx-click="toggle_dropdown"
          phx-target={@myself}
          class={[
            "flex items-center gap-1.5 rounded px-1.5 py-0.5 text-[11px] transition-all duration-150 interactive",
            if(@dropdown_open,
              do: "text-secondary bg-surface-2",
              else: "text-muted hover:text-secondary"
            )
          ]}
        >
          <.icon name="hero-chat-bubble-left-right-mini" class="w-3 h-3 flex-shrink-0 opacity-60" />
          <span class="truncate max-w-[160px]">{current_session_label(@session_id, @sessions)}</span>
          <svg
            class={[
              "w-2.5 h-2.5 flex-shrink-0 transition-transform duration-150 opacity-50",
              @dropdown_open && "rotate-180"
            ]}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2.5"
              d="M19 9l-7 7-7-7"
            />
          </svg>
        </button>

        <span
          :if={@session_index && length(@sessions) > 1}
          class="text-[10px] text-muted tabular-nums"
        >
          {session_count_label(@session_index, length(@sessions))}
        </span>

        <div class="flex-1" />

        <button
          phx-click="new_session"
          phx-target={@myself}
          class="flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] text-muted hover:text-brand transition-colors interactive"
          title="New session"
        >
          <.icon name="hero-plus-mini" class="w-3 h-3" />
        </button>
      </div>

      <%!-- Dropdown --%>
      <div
        :if={@dropdown_open}
        class="absolute left-2 top-full mt-0.5 w-64 card-elevated overflow-hidden animate-scale-in"
        style="z-index: 100;"
      >
        <%!-- New session option --%>
        <button
          phx-click="new_session"
          phx-target={@myself}
          class="w-full flex items-center gap-2 px-3 py-1.5 text-xs transition-colors interactive text-brand border-b border-subtle"
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
            class={[
              "w-full flex items-center gap-2 px-3 py-1.5 text-xs transition-colors interactive",
              if(session.id == @session_id,
                do: "bg-brand-subtle text-brand",
                else: "text-secondary"
              )
            ]}
          >
            <span :if={session.id == @session_id} class="flex-shrink-0">
              <span class="text-brand">
                <.icon name="hero-check-mini" class="w-3 h-3" />
              </span>
            </span>
            <span :if={session.id != @session_id} class="w-3 flex-shrink-0" />
            <span class="truncate flex-1 text-left">{session_label(session)}</span>
            <span class="text-[10px] flex-shrink-0 text-muted">
              {session_relative_time(session)}
            </span>
          </button>
        </div>

        <div
          :if={@sessions == []}
          class="px-3 py-3 text-xs text-center text-muted"
        >
          No previous sessions
        </div>
      </div>
    </div>
    """
  end

  @impl true
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

  defp session_relative_time(session) do
    datetime = Map.get(session, :updated_at) || Map.get(session, :inserted_at)
    LoomkinWeb.TimeHelpers.relative_time(datetime)
  rescue
    e ->
      Logger.debug("[SessionSwitcher] relative_time failed: #{Exception.message(e)}")
      "just now"
  end

  defp current_session_index(session_id, sessions) when is_list(sessions) do
    case Enum.find_index(sessions, &(&1.id == session_id)) do
      nil -> nil
      idx -> idx + 1
    end
  end

  defp current_session_index(_session_id, _sessions), do: nil

  defp session_count_label(index, total) do
    "#{index} of #{total}"
  end
end
