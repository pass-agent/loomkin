defmodule LoomkinWeb.TeamTreeComponent do
  use LoomkinWeb, :live_component

  def mount(socket) do
    {:ok, assign(socket, open: false, confirm_kill: nil)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("toggle_tree", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open, confirm_kill: nil)}
  end

  def handle_event("close_tree", _params, socket) do
    {:noreply, assign(socket, open: false, confirm_kill: nil)}
  end

  def handle_event("select_team", %{"team-id" => team_id}, socket) do
    tree = socket.assigns.team_tree

    known =
      Map.has_key?(tree, team_id) or Enum.any?(tree, fn {_, children} -> team_id in children end)

    if known do
      send(self(), {:switch_team, team_id})
      {:noreply, assign(socket, open: false, confirm_kill: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("kill_team", %{"team-id" => team_id}, socket) do
    if socket.assigns.confirm_kill == team_id do
      send(self(), {:kill_team, team_id})
      {:noreply, assign(socket, open: false, confirm_kill: nil)}
    else
      {:noreply, assign(socket, confirm_kill: team_id)}
    end
  end

  def handle_event("cancel_kill", _params, socket) do
    {:noreply, assign(socket, confirm_kill: nil)}
  end

  def handle_event("kill_all_teams", _params, socket) do
    {:noreply, assign(socket, confirm_kill: :all)}
  end

  def handle_event("confirm_kill_all", _params, socket) do
    send(self(), :kill_all_teams)
    {:noreply, assign(socket, open: false, confirm_kill: nil)}
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="relative">
      <button
        :if={@team_tree != %{}}
        type="button"
        phx-click="toggle_tree"
        phx-target={@myself}
        class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs font-medium bg-surface-2 border border-subtle text-secondary hover:text-primary hover:bg-surface-3 transition-colors"
      >
        <span>Teams</span>
        <svg
          class={["w-3 h-3 transition-transform", @open && "rotate-180"]}
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
        >
          <path d="M2 4l4 4 4-4" />
        </svg>
      </button>
      <div
        :if={@open}
        class="absolute top-full left-0 mt-1.5 w-64 rounded-xl overflow-hidden z-[9999] bg-surface-2 border border-default shadow-lg"
        phx-click-away="close_tree"
        phx-target={@myself}
      >
        <.team_subtree
          team_id={@root_team_id}
          depth={0}
          team_tree={@team_tree}
          active_team_id={@active_team_id}
          agent_counts={@agent_counts}
          team_names={@team_names}
          myself={@myself}
          root_team_id={@root_team_id}
          confirm_kill={@confirm_kill}
        />
        <%!-- Kill all sub-teams button at the bottom --%>
        <div
          :if={@team_tree != %{} && map_size(@team_tree) > 0}
          class="border-t border-border-subtle px-2 py-1.5"
        >
          <button
            :if={@confirm_kill != :all}
            type="button"
            phx-click="kill_all_teams"
            phx-target={@myself}
            class="w-full flex items-center justify-center gap-1.5 px-2 py-1 rounded-md text-[11px] text-red-400/70 hover:text-red-300 hover:bg-red-500/10 transition-colors"
          >
            <.icon name="hero-stop-mini" class="w-3 h-3" />
            <span>Stop all teams</span>
          </button>
          <div :if={@confirm_kill == :all} class="flex items-center gap-1">
            <span class="text-[10px] text-red-300 flex-1">Stop all teams?</span>
            <button
              type="button"
              phx-click="confirm_kill_all"
              phx-target={@myself}
              class="px-2 py-0.5 rounded text-[10px] font-medium bg-red-500/20 text-red-300 hover:bg-red-500/30 transition-colors"
            >
              Confirm
            </button>
            <button
              type="button"
              phx-click="cancel_kill"
              phx-target={@myself}
              class="px-2 py-0.5 rounded text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp team_subtree(assigns) do
    ~H"""
    <.team_row
      team_id={@team_id}
      depth={@depth}
      active_team_id={@active_team_id}
      agent_counts={@agent_counts}
      team_names={@team_names}
      myself={@myself}
      root_team_id={@root_team_id}
      confirm_kill={@confirm_kill}
    />
    <%= for child_id <- Map.get(@team_tree, @team_id, []) do %>
      <.team_subtree
        team_id={child_id}
        depth={@depth + 1}
        team_tree={@team_tree}
        active_team_id={@active_team_id}
        agent_counts={@agent_counts}
        team_names={@team_names}
        myself={@myself}
        root_team_id={@root_team_id}
        confirm_kill={@confirm_kill}
      />
    <% end %>
    """
  end

  defp team_row(assigns) do
    assigns = assign(assigns, :is_sub_team, assigns.team_id != assigns.root_team_id)

    ~H"""
    <div class="group/row flex items-center hover:bg-surface-3 transition-colors">
      <button
        type="button"
        phx-click="select_team"
        phx-value-team-id={@team_id}
        phx-target={@myself}
        class={[
          "flex-1 flex items-center justify-between py-2 text-xs text-left min-w-0",
          @team_id == @active_team_id && "font-medium text-primary",
          @team_id != @active_team_id && "text-secondary"
        ]}
        style={"padding-left: #{12 + @depth * 12}px"}
      >
        <span class="truncate">{Map.get(@team_names, @team_id, short_id(@team_id))}</span>
        <span class="ml-2 text-tertiary tabular-nums">{Map.get(@agent_counts, @team_id, 0)}</span>
      </button>
      <%!-- Kill button for sub-teams --%>
      <div :if={@is_sub_team} class="flex-shrink-0 pr-2">
        <%= if @confirm_kill == @team_id do %>
          <div class="flex items-center gap-0.5">
            <button
              type="button"
              phx-click="kill_team"
              phx-value-team-id={@team_id}
              phx-target={@myself}
              class="px-1.5 py-0.5 rounded text-[10px] font-medium bg-red-500/20 text-red-300 hover:bg-red-500/30 transition-colors"
              title="Confirm stop"
            >
              Stop
            </button>
            <button
              type="button"
              phx-click="cancel_kill"
              phx-target={@myself}
              class="px-1 py-0.5 rounded text-[10px] text-zinc-500 hover:text-zinc-300 transition-colors"
              title="Cancel"
            >
              ✕
            </button>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="kill_team"
            phx-value-team-id={@team_id}
            phx-target={@myself}
            class="opacity-0 group-hover/row:opacity-100 p-0.5 rounded text-red-400/60 hover:text-red-300 hover:bg-red-500/10 transition-all"
            title="Stop this team"
          >
            <.icon name="hero-stop-mini" class="w-3.5 h-3.5" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "unknown"
end
