defmodule LoomkinWeb.Mobile.SessionListLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Repo
  alias Loomkin.Schemas.Session
  alias Loomkin.Workspace

  import Ecto.Query
  import LoomkinWeb.Mobile.Layout

  def mount(%{"id" => workspace_id}, _session, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user

    case Repo.get(Workspace, workspace_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> push_navigate(to: ~p"/m")}

      workspace ->
        if user && workspace.user_id == user.id do
          socket =
            socket
            |> assign(
              page_title: workspace.name,
              workspace: workspace
            )
            |> stream(:sessions, [], dom_id: &"sess-#{&1.id}")

          socket =
            if connected?(socket) do
              sessions = load_sessions(workspace_id)
              stream(socket, :sessions, sessions, reset: true)
            else
              socket
            end

          {:ok, socket}
        else
          {:ok,
           socket
           |> put_flash(:error, "Not authorized")
           |> push_navigate(to: ~p"/m")}
        end
    end
  end

  defp load_sessions(workspace_id) do
    Session
    |> where([s], s.workspace_id == ^workspace_id)
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  def render(assigns) do
    ~H"""
    <.mobile_layout page_title={@workspace.name} back_path={~p"/m"}>
      <div class="px-4 pt-4">
        <.link
          navigate={~p"/m/sessions/new?#{%{workspace_id: @workspace.id}}"}
          class="flex items-center justify-center gap-2 w-full py-3.5 bg-violet-600 hover:bg-violet-500 active:bg-violet-700 text-white text-sm font-medium rounded-xl transition-colors"
          id="new-session-btn"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-5 h-5"
          >
            <path d="M10.75 4.75a.75.75 0 00-1.5 0v4.5h-4.5a.75.75 0 000 1.5h4.5v4.5a.75.75 0 001.5 0v-4.5h4.5a.75.75 0 000-1.5h-4.5v-4.5z" />
          </svg>
          New Session
        </.link>

        <div id="sessions" phx-update="stream" class="mt-4 space-y-3">
          <div class="hidden only:block text-center py-16 px-6">
            <p class="text-gray-400 text-sm">No sessions yet</p>
            <p class="text-gray-600 text-xs mt-1">
              Tap "New Session" to start working.
            </p>
          </div>
          <.link
            :for={{id, session} <- @streams.sessions}
            id={id}
            navigate={~p"/m/sessions/#{session.id}"}
            class="block bg-gray-900 border border-gray-800 rounded-xl p-4 active:bg-gray-800 transition-colors"
          >
            <div class="flex items-center justify-between gap-3">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <h3 class="text-white text-sm font-medium truncate">
                    {session.title || "Untitled Session"}
                  </h3>
                  <span class={[
                    "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider shrink-0",
                    if(session.status == :active,
                      do: "bg-emerald-500/15 text-emerald-400",
                      else: "bg-gray-700/50 text-gray-500"
                    )
                  ]}>
                    {session.status}
                  </span>
                </div>
                <div class="flex items-center gap-3 mt-1">
                  <span :if={session.model} class="text-gray-500 text-xs font-mono truncate">
                    {session.model}
                  </span>
                  <span class="text-gray-600 text-xs">
                    {format_relative_time(session.updated_at)}
                  </span>
                  <span
                    :if={session.cost_usd && Decimal.gt?(session.cost_usd, Decimal.new("0"))}
                    class="text-gray-600 text-xs"
                  >
                    ${format_cost(session.cost_usd)}
                  </span>
                </div>
              </div>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-gray-600 shrink-0"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
                  clip-rule="evenodd"
                />
              </svg>
            </div>
          </.link>
        </div>
      </div>
    </.mobile_layout>
    """
  end

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp format_cost(%Decimal{} = d), do: Decimal.round(d, 4) |> Decimal.to_string()
  defp format_cost(_), do: "0"
end
