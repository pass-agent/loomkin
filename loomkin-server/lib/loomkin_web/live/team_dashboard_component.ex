defmodule LoomkinWeb.TeamDashboardComponent do
  use LoomkinWeb, :live_component

  alias Loomkin.Teams.CostTracker
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Tasks

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket, agents: [], tasks: [], budget: %{spent: 0, limit: 5.0}, subscribed: false)}
  end

  @impl true
  def update(%{team_id: _team_id} = assigns, socket) do
    prev_team_id = socket.assigns[:team_id]

    if !socket.assigns[:subscribed] do
      Loomkin.Signals.subscribe("agent.status")
      Loomkin.Signals.subscribe("agent.escalation")
      Loomkin.Signals.subscribe("agent.role.changed")
      Loomkin.Signals.subscribe("team.task.*")
    end

    socket =
      socket
      |> assign(assigns)
      |> assign(:subscribed, true)

    if prev_team_id != socket.assigns.team_id do
      {:ok, load_team_data(socket)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp load_team_data(socket) do
    team_id = socket.assigns.team_id

    agents =
      Manager.list_agents(team_id)
      |> Enum.map(fn agent ->
        current_task = find_agent_current_task(team_id, agent.name)

        %{
          name: agent.name,
          role: agent.role,
          status: agent.status || :idle,
          current_task: current_task
        }
      end)

    tasks = Tasks.list_all(team_id)

    summary = CostTracker.team_cost_summary(team_id)
    spent = to_float(summary.total_cost_usd)
    budget_limit = socket.assigns.budget[:limit] || 5.0

    socket
    |> assign(:agents, agents)
    |> assign(:tasks, tasks)
    |> assign(:budget, %{spent: spent, limit: budget_limit})
  end

  defp find_agent_current_task(team_id, agent_name) do
    case Tasks.list_by_agent(team_id, agent_name) do
      [] ->
        nil

      agent_tasks ->
        agent_tasks
        |> Enum.find(fn t -> t.status in [:assigned, :in_progress] end)
        |> case do
          nil -> nil
          task -> task.title
        end
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_), do: 0.0

  # --- Signal handlers ---

  def handle_info(
        %Jido.Signal{type: "agent.status", data: %{agent_name: agent_name, status: status}},
        socket
      ) do
    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if agent.name == agent_name, do: %{agent | status: status}, else: agent
      end)

    {:noreply, assign(socket, :agents, agents)}
  end

  def handle_info(
        %Jido.Signal{type: "team.task.assigned", data: %{agent_name: agent_name}},
        socket
      ) do
    {:noreply, schedule_reload(socket, agent_name)}
  end

  def handle_info(%Jido.Signal{type: "team.task.completed", data: %{owner: owner}}, socket) do
    {:noreply, schedule_reload(socket, owner)}
  end

  def handle_info(%Jido.Signal{type: "team.task.started", data: %{owner: owner}}, socket) do
    {:noreply, schedule_reload(socket, owner)}
  end

  def handle_info(%Jido.Signal{type: "team.task.failed", data: %{owner: owner}}, socket) do
    {:noreply, schedule_reload(socket, owner)}
  end

  def handle_info(
        %Jido.Signal{
          type: "agent.role.changed",
          data: %{agent_name: agent_name, new_role: new_role}
        },
        socket
      ) do
    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if agent.name == agent_name, do: %{agent | role: new_role}, else: agent
      end)

    {:noreply, assign(socket, :agents, agents)}
  end

  def handle_info(%Jido.Signal{type: "agent.escalation", data: %{agent_name: agent_name}}, socket) do
    # Escalation may affect budget — schedule debounced reload
    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if agent.name == agent_name, do: %{agent | status: :working}, else: agent
      end)

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> schedule_reload(agent_name)}
  end

  def handle_info(:reload_dashboard, socket) do
    dirty = socket.assigns[:dirty_agents] || MapSet.new()

    {:noreply,
     socket
     |> assign(reload_timer: nil, dirty_agents: MapSet.new())
     |> reload_tasks(dirty)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp schedule_reload(socket, agent_name) do
    if timer = socket.assigns[:reload_timer] do
      Process.cancel_timer(timer)
    end

    dirty = socket.assigns[:dirty_agents] || MapSet.new()
    dirty = MapSet.put(dirty, agent_name)
    timer = Process.send_after(self(), :reload_dashboard, 500)
    assign(socket, reload_timer: timer, dirty_agents: dirty)
  end

  defp reload_tasks(socket, dirty_agents) do
    team_id = socket.assigns.team_id
    tasks = Tasks.list_all(team_id)

    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if MapSet.member?(dirty_agents, agent.name) do
          current_task = find_agent_current_task(team_id, agent.name)
          %{agent | current_task: current_task}
        else
          agent
        end
      end)

    summary = CostTracker.team_cost_summary(team_id)
    spent = to_float(summary.total_cost_usd)
    budget_limit = socket.assigns.budget[:limit] || 5.0

    socket
    |> assign(:tasks, tasks)
    |> assign(:agents, agents)
    |> assign(:budget, %{spent: spent, limit: budget_limit})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-950 border border-gray-800 rounded-lg overflow-hidden">
      <%!-- Header --%>
      <div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold text-violet-400">Kin: {@team_id}</span>
        </div>
        <span class="text-xs text-gray-500">{length(@agents)} agents</span>
      </div>

      <div class="p-4 space-y-4">
        <%!-- Agents Section --%>
        <div class="bg-gray-900 border border-gray-800 rounded-lg">
          <div class="px-3 py-2 border-b border-gray-800">
            <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider">Agents</h3>
          </div>
          <div class="divide-y divide-gray-800/50">
            <div :if={@agents == []} class="px-3 py-4 text-center text-xs text-gray-600">
              No kin spawned
            </div>
            <div
              :for={agent <- @agents}
              class="flex items-center gap-3 px-3 py-2 hover:bg-gray-800/30"
            >
              <span class={"w-2 h-2 rounded-full flex-shrink-0 #{status_dot_color(agent.status)}"}>
              </span>
              <span class="text-sm text-gray-100 font-medium w-24 truncate">{agent.name}</span>
              <span class={"text-xs w-16 #{status_text_color(agent.status)}"}>{agent.status}</span>
              <span class="text-xs text-gray-500 truncate flex-1">
                {agent.current_task || "\u2014"}
              </span>
            </div>
          </div>
        </div>

        <%!-- Tasks Section --%>
        <div class="bg-gray-900 border border-gray-800 rounded-lg">
          <div class="px-3 py-2 border-b border-gray-800">
            <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider">Tasks</h3>
          </div>
          <div class="divide-y divide-gray-800/50">
            <div :if={@tasks == []} class="px-3 py-4 text-center text-xs text-gray-600">
              No tasks created
            </div>
            <div
              :for={task <- @tasks}
              class="flex items-center gap-3 px-3 py-2 hover:bg-gray-800/30"
            >
              <span class="flex-shrink-0 w-4 text-center">{task_status_icon(task.status)}</span>
              <span class="text-sm text-gray-100 truncate flex-1">{task.title}</span>
              <span class="text-xs text-gray-500 w-20 truncate text-right">
                {task.owner || "\u2014"}
              </span>
              <span class="text-xs text-gray-400 w-16 text-right font-mono">
                {format_cost(task.cost_usd)}
              </span>
            </div>
          </div>
        </div>

        <%!-- Budget Bar --%>
        <div class="bg-gray-900 border border-gray-800 rounded-lg px-3 py-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs text-gray-400">Budget</span>
            <span class="text-xs text-gray-300 font-mono">
              ${format_decimal(@budget.spent)} / ${format_decimal(@budget.limit)}
              <span class={"ml-1 #{budget_pct_color(@budget)}"}>
                {budget_percentage(@budget)}%
              </span>
            </span>
          </div>
          <div class="w-full bg-gray-800 rounded-full h-2">
            <div
              class={"h-2 rounded-full transition-all duration-300 #{budget_bar_color(@budget)}"}
              style={"width: #{min(budget_percentage(@budget), 100)}%"}
            >
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Status helpers ---

  defp status_dot_color(:working), do: "bg-green-400"
  defp status_dot_color(:idle), do: "bg-gray-500"
  defp status_dot_color(:blocked), do: "bg-yellow-400"
  defp status_dot_color(:error), do: "bg-red-400"
  defp status_dot_color(_), do: "bg-gray-500"

  defp status_text_color(:working), do: "text-green-400"
  defp status_text_color(:idle), do: "text-gray-500"
  defp status_text_color(:blocked), do: "text-yellow-400"
  defp status_text_color(:error), do: "text-red-400"
  defp status_text_color(_), do: "text-gray-500"

  defp task_status_icon(:completed),
    do: Phoenix.HTML.raw(~s(<span class="text-green-400">&#10003;</span>))

  defp task_status_icon(:in_progress),
    do:
      Phoenix.HTML.raw(~s(<span class="text-violet-400 animate-spin inline-block">&#8635;</span>))

  defp task_status_icon(:assigned),
    do: Phoenix.HTML.raw(~s(<span class="text-blue-400">&#8635;</span>))

  defp task_status_icon(:pending),
    do: Phoenix.HTML.raw(~s(<span class="text-gray-500">&#9719;</span>))

  defp task_status_icon(:failed),
    do: Phoenix.HTML.raw(~s(<span class="text-red-400">&#10007;</span>))

  defp task_status_icon(_), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">&#8226;</span>))

  # --- Budget helpers ---

  defp budget_percentage(%{spent: spent, limit: limit}) when limit > 0 do
    Float.round(spent / limit * 100, 1)
  end

  defp budget_percentage(_), do: 0.0

  defp budget_bar_color(budget) do
    pct = budget_percentage(budget)

    cond do
      pct >= 80 -> "bg-red-500"
      pct >= 50 -> "bg-yellow-500"
      true -> "bg-green-500"
    end
  end

  defp budget_pct_color(budget) do
    pct = budget_percentage(budget)

    cond do
      pct >= 80 -> "text-red-400"
      pct >= 50 -> "text-yellow-400"
      true -> "text-green-400"
    end
  end

  # --- Formatting helpers ---

  defp format_cost(%Decimal{} = d) do
    val = Decimal.to_float(d)
    if val > 0, do: "$#{:erlang.float_to_binary(val, decimals: 2)}", else: "\u2014"
  end

  defp format_cost(n) when is_number(n) and n > 0,
    do: "$#{:erlang.float_to_binary(n / 1, decimals: 2)}"

  defp format_cost(_), do: "\u2014"

  defp format_decimal(n) when is_number(n),
    do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_decimal(_), do: "0.00"
end
