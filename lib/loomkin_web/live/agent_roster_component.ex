defmodule LoomkinWeb.AgentRosterComponent do
  @moduledoc """
  Left-panel sidebar for mission control mode.

  Displays agent roster with status indicators, task summary, and budget bar.
  Communicates focus/unpin actions to the parent LiveView via `send(self(), msg)`.
  """

  use LoomkinWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, tasks_collapsed: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, Map.put_new(assigns, :channel_bindings, []))}
  end

  @impl true
  def handle_event("focus_agent", %{"agent" => agent_name}, socket) do
    if socket.assigns[:focused_agent] == agent_name do
      send(self(), {:unpin_agent})
    else
      send(self(), {:focus_agent, agent_name})
    end

    {:noreply, socket}
  end

  def handle_event("reply_agent", %{"agent" => agent_name, "team-id" => team_id}, socket) do
    send(self(), {:reply_to_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_event("toggle_tasks", _params, socket) do
    {:noreply, assign(socket, tasks_collapsed: !socket.assigns.tasks_collapsed)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-56 w-full flex-col bg-surface-1 xl:h-full xl:w-64 xl:border-r border-subtle">
      <%!-- Team Header --%>
      <div class="px-4 py-3 flex items-center justify-between">
        <div class="flex items-center gap-2 min-w-0">
          <span class="text-sm font-semibold text-brand truncate font-mono">{@team_id}</span>
          {channel_badges(assigns)}
        </div>
        <span class="badge text-[10px] tabular-nums">
          {length(@agents)}
        </span>
      </div>

      <div class="divider"></div>

      <%!-- Agents Section --%>
      <div class="flex-1 overflow-y-auto">
        <div class="px-4 pt-3 pb-1">
          <h3 class="text-[10px] font-semibold text-muted uppercase tracking-widest">Agents</h3>
        </div>

        <div :if={@agents == []} class="px-4 py-8 text-center">
          <div class="text-muted text-xs">No agents spawned</div>
          <div class="text-[10px] mt-1" style="color: var(--text-muted); opacity: 0.5;">
            Waiting for team initialization...
          </div>
        </div>

        <div class="space-y-1 px-2 pb-2">
          <div
            :for={agent <- @agents}
            phx-click="focus_agent"
            phx-value-agent={agent.name}
            phx-target={@myself}
            class={[
              "group rounded-lg px-3 py-2 cursor-pointer interactive press-down",
              if(@focused_agent == agent.name,
                do: "card-brand",
                else: "border border-transparent hover:bg-surface-2"
              )
            ]}
          >
            <%!-- Row 1: status dot + name + role badge + reply button --%>
            <div class="flex items-center gap-2.5">
              <span class={[
                "w-2 h-2 rounded-full flex-shrink-0",
                status_dot_class(agent.status)
              ]}>
              </span>
              <span
                class="text-sm font-medium truncate flex-1"
                style={"color: #{agent_color(agent.name)}"}
              >
                {agent.name}
              </span>
              <span
                class="text-[10px] px-1.5 py-0.5 rounded font-medium text-muted"
                style="background: var(--brand-muted);"
              >
                {format_role(agent.role)}
              </span>
              <button
                phx-click="reply_agent"
                phx-value-agent={agent.name}
                phx-value-team-id={agent.team_id}
                phx-target={@myself}
                title={"Reply to #{agent.name}"}
                class="text-muted hover:text-brand opacity-0 group-hover:opacity-100 p-1 rounded-md hover:bg-surface-3 flex-shrink-0"
                style="transition: opacity var(--transition-base), color var(--transition-base), background var(--transition-base);"
              >
                <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
                  <path
                    fill-rule="evenodd"
                    d="M7.707 3.293a1 1 0 010 1.414L5.414 7H11a7 7 0 017 7v2a1 1 0 11-2 0v-2a5 5 0 00-5-5H5.414l2.293 2.293a1 1 0 11-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z"
                    clip-rule="evenodd"
                  />
                </svg>
              </button>
            </div>
            <%!-- Row 2: current task --%>
            <div class="mt-1 pl-[18px]">
              <span class={["text-xs font-mono", status_text_class(agent.status)]}>
                {Map.get(agent, :current_task) || status_label(agent.status)}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div class="divider"></div>

      <%!-- Tasks Section (collapsible) --%>
      <div class="flex-shrink-0">
        <button
          phx-click="toggle_tasks"
          phx-target={@myself}
          class="w-full flex items-center justify-between px-4 py-2.5 hover:bg-surface-2 cursor-pointer"
          style="transition: background var(--transition-base);"
        >
          <h3 class="text-[10px] font-semibold text-muted uppercase tracking-widest">Tasks</h3>
          <svg
            class={[
              "w-3.5 h-3.5 text-muted chevron-rotate",
              if(!@tasks_collapsed, do: "expanded", else: "")
            ]}
            viewBox="0 0 20 20"
            fill="currentColor"
          >
            <path
              fill-rule="evenodd"
              d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z"
              clip-rule="evenodd"
            />
          </svg>
        </button>

        <div :if={!@tasks_collapsed} class="max-h-48 overflow-y-auto">
          <div :if={@tasks == []} class="px-4 py-4 text-center">
            <span class="text-xs text-muted">No tasks</span>
          </div>

          <div class="space-y-0.5 px-2 pb-2">
            <div
              :for={task <- @tasks}
              class="flex items-center gap-2 px-3 py-1.5 rounded-md hover:bg-surface-2"
              style="transition: background var(--transition-base);"
            >
              <span class="flex-shrink-0 w-4 text-center">{task_status_icon(task.status)}</span>
              <span class="text-xs truncate flex-1" style="color: var(--text-secondary);">
                {task.title}
              </span>
              <span
                :if={task.owner not in [nil, ""]}
                class="text-[10px] truncate max-w-[4rem] text-right font-mono text-muted"
              >
                {task.owner}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div class="divider"></div>

      <%!-- Budget Bar --%>
      <div class="flex-shrink-0 px-4 py-3">
        <div class="flex items-center justify-between mb-2">
          <span class="text-[10px] font-semibold text-muted uppercase tracking-widest">Budget</span>
          <span class="text-[11px] font-mono tabular-nums" style="color: var(--text-secondary);">
            <span>$</span>{format_decimal(@budget.spent)}<span class="text-muted">&nbsp;/&nbsp;$</span>{format_decimal(
              @budget.limit
            )}
          </span>
        </div>
        <div class="w-full rounded-full h-1.5 overflow-hidden" style="background: var(--surface-3);">
          <div
            class={["h-full rounded-full", budget_bar_class(@budget)]}
            style={"width: #{min(budget_percentage(@budget), 100)}%; transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);"}
          >
          </div>
        </div>
        <div class="text-right mt-1">
          <span class={["text-[10px] font-mono tabular-nums", budget_pct_color(@budget)]}>
            {budget_percentage(@budget)}%
          </span>
        </div>
      </div>
    </div>
    """
  end

  # --- Channel badge helpers ---

  defp channel_badges(assigns) do
    telegram_count =
      Enum.count(assigns.channel_bindings, &(&1.channel == :telegram))

    discord_count =
      Enum.count(assigns.channel_bindings, &(&1.channel == :discord))

    assigns =
      assigns
      |> assign(:telegram_count, telegram_count)
      |> assign(:discord_count, discord_count)

    ~H"""
    <span
      :if={@telegram_count > 0}
      class="badge-success text-[10px] gap-0.5"
      title={"#{@telegram_count} Telegram binding#{if @telegram_count > 1, do: "s", else: ""}"}
    >
      <svg class="w-3 h-3" viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z" />
      </svg>
      {if @telegram_count > 1, do: @telegram_count, else: ""}
    </span>
    <span
      :if={@discord_count > 0}
      class="badge text-[10px] gap-0.5"
      title={"#{@discord_count} Discord binding#{if @discord_count > 1, do: "s", else: ""}"}
    >
      <svg class="w-3 h-3" viewBox="0 0 24 24" fill="currentColor">
        <path d="M20.317 4.37a19.791 19.791 0 00-4.885-1.515.074.074 0 00-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 00-5.487 0 12.64 12.64 0 00-.617-1.25.077.077 0 00-.079-.037A19.736 19.736 0 003.677 4.37a.07.07 0 00-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 00.031.057 19.9 19.9 0 005.993 3.03.078.078 0 00.084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 00-.041-.106 13.107 13.107 0 01-1.872-.892.077.077 0 01-.008-.128 10.2 10.2 0 00.372-.292.074.074 0 01.077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 01.078.01c.12.098.246.198.373.292a.077.077 0 01-.006.127 12.299 12.299 0 01-1.873.892.077.077 0 00-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 00.084.028 19.839 19.839 0 006.002-3.03.077.077 0 00.032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 00-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
      </svg>
      {if @discord_count > 1, do: @discord_count, else: ""}
    </span>
    """
  end

  # --- Agent color hash ---

  defp agent_color(name), do: LoomkinWeb.AgentColors.agent_color(name)

  # --- Status helpers ---

  defp status_dot_class(:working), do: "bg-green-400 agent-dot-working"
  defp status_dot_class(:idle), do: "bg-zinc-500"
  defp status_dot_class(:blocked), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(:error), do: "bg-red-400 agent-dot-error"
  defp status_dot_class(:waiting_permission), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(_), do: "bg-zinc-500"

  defp status_text_class(:working), do: "text-green-400"
  defp status_text_class(:idle), do: "text-muted"
  defp status_text_class(:blocked), do: "text-amber-400"
  defp status_text_class(:error), do: "text-red-400"
  defp status_text_class(:waiting_permission), do: "text-amber-400"
  defp status_text_class(_), do: "text-muted"

  defp status_label(:working), do: "working"
  defp status_label(:idle), do: "idle"
  defp status_label(:blocked), do: "blocked"
  defp status_label(:error), do: "error"
  defp status_label(:waiting_permission), do: "awaiting"
  defp status_label(_), do: "idle"

  # --- Task status icons ---

  defp task_status_icon(:completed),
    do: Phoenix.HTML.raw(~s(<span class="text-green-400">&#10003;</span>))

  defp task_status_icon(:in_progress),
    do: Phoenix.HTML.raw(~s(<span class="text-brand animate-spin inline-block">&#9684;</span>))

  defp task_status_icon(:assigned),
    do: Phoenix.HTML.raw(~s[<span style="color: var(--accent-cyan);">&#8594;</span>])

  defp task_status_icon(:pending),
    do: Phoenix.HTML.raw(~s(<span class="text-muted">&#9675;</span>))

  defp task_status_icon(:failed),
    do: Phoenix.HTML.raw(~s(<span class="text-red-400">&#10007;</span>))

  defp task_status_icon(_),
    do: Phoenix.HTML.raw(~s(<span class="text-muted">&#8226;</span>))

  # --- Budget helpers ---

  defp budget_percentage(%{spent: spent, limit: limit}) when limit > 0 do
    Float.round(spent / limit * 100, 1)
  end

  defp budget_percentage(_), do: 0.0

  defp budget_bar_class(budget) do
    pct = budget_percentage(budget)

    cond do
      pct >= 80 -> "bg-gradient-to-r from-red-500 to-rose-400"
      pct >= 50 -> "bg-gradient-to-r from-amber-500 to-yellow-400"
      true -> "bg-gradient-to-r from-emerald-500 to-green-400"
    end
  end

  defp budget_pct_color(budget) do
    pct = budget_percentage(budget)

    cond do
      pct >= 80 -> "text-red-400"
      pct >= 50 -> "text-amber-400"
      true -> "text-emerald-400"
    end
  end

  # --- Formatting helpers ---

  defp format_decimal(n) when is_number(n),
    do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_decimal(_), do: "0.00"

  defp format_role(role) when is_atom(role), do: role |> Atom.to_string() |> format_role()
  defp format_role(role) when is_binary(role), do: String.slice(role, 0, 8)
  defp format_role(_), do: "-"
end
