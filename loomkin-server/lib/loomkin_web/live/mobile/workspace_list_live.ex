defmodule LoomkinWeb.Mobile.WorkspaceListLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Repo
  alias Loomkin.Relay.Server.Registry
  alias Loomkin.Workspace

  import Ecto.Query
  import LoomkinWeb.Mobile.Layout

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Workspaces")
      |> stream(:workspaces, [], dom_id: &"ws-#{&1.id}")

    socket =
      if connected?(socket) do
        user = socket.assigns[:current_scope] && socket.assigns.current_scope.user
        workspaces = load_workspaces(user)
        stream(socket, :workspaces, workspaces, reset: true)
      else
        socket
      end

    {:ok, socket}
  end

  defp load_workspaces(nil), do: []

  defp load_workspaces(user) do
    workspaces =
      Workspace
      |> where([w], w.user_id == ^user.id and w.status != :archived)
      |> order_by([w], desc: w.updated_at)
      |> Repo.all()

    online_map = get_online_status(user.id)

    Enum.map(workspaces, fn ws ->
      info = Map.get(online_map, ws.id)

      ws
      |> Map.put(:online, info != nil)
      |> Map.put(:machine_name, info && info.machine_name)
      |> Map.put(:agent_count, (info && info.agent_count) || 0)
    end)
  end

  defp get_online_status(user_id) do
    Registry.list_workspaces(user_id)
    |> Map.new(fn {ws_id, info} -> {ws_id, info} end)
  rescue
    _ -> %{}
  end

  def render(assigns) do
    ~H"""
    <.mobile_layout page_title="Workspaces">
      <div class="px-4 pt-4 space-y-3">
        <div id="workspaces" phx-update="stream">
          <div class="hidden only:block text-center py-20 px-6">
            <div class="text-gray-600 mb-3">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                class="w-12 h-12 mx-auto"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25"
                />
              </svg>
            </div>
            <p class="text-gray-400 text-sm font-medium">No workspaces yet</p>
            <p class="text-gray-600 text-xs mt-1">
              Start Loomkin on your computer to see projects here.
            </p>
          </div>
          <.link
            :for={{id, ws} <- @streams.workspaces}
            id={id}
            navigate={~p"/m/workspaces/#{ws.id}"}
            class="block bg-gray-900 border border-gray-800 rounded-xl p-4 active:bg-gray-800 transition-colors mb-3"
          >
            <div class="flex items-center gap-3">
              <div class={[
                "w-2.5 h-2.5 rounded-full shrink-0",
                if(ws.online, do: "bg-emerald-400", else: "bg-gray-600")
              ]} />
              <div class="min-w-0 flex-1">
                <h3 class="text-white font-medium text-sm truncate">{ws.name}</h3>
                <div class="flex items-center gap-2 mt-0.5">
                  <span :if={ws.machine_name} class="text-gray-500 text-xs truncate">
                    {ws.machine_name}
                  </span>
                  <span :if={ws.agent_count > 0} class="text-gray-600 text-xs">
                    {ws.agent_count} {if ws.agent_count == 1, do: "agent", else: "agents"}
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
end
