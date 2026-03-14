defmodule LoomkinWeb.TeamCostComponent do
  @moduledoc "Per-team cost analytics panel: agent token bars, model breakdown, budget gauge, escalations, timeline."

  use LoomkinWeb, :live_component

  alias Loomkin.Teams.CostTracker

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       agent_costs: [],
       model_costs: [],
       budget: %{spent: 0.0, limit: 5.0},
       escalations: [],
       timeline: [],
       subscribed: false
     )}
  end

  @impl true
  def update(%{team_id: _team_id} = assigns, socket) do
    prev_team_id = socket.assigns[:team_id]

    if connected?(socket) && !socket.assigns[:subscribed] do
      Loomkin.Signals.subscribe("agent.usage")
      Loomkin.Signals.subscribe("agent.escalation")
      Loomkin.Signals.subscribe("team.task.completed")
      Loomkin.Signals.subscribe("system.metrics.updated")
    end

    socket =
      socket
      |> assign(assigns)
      |> assign(:subscribed, true)

    # Only load cost data on first mount or when team_id changes
    if prev_team_id != socket.assigns.team_id do
      {:ok, load_cost_data(socket)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  defp load_cost_data(socket) do
    team_id = socket.assigns.team_id
    budget_limit = socket.assigns.budget[:limit] || 5.0

    # Per-agent usage from ETS
    agent_usage = CostTracker.get_team_usage(team_id)

    # Fetch call history once per agent, reuse for model breakdown and timeline
    all_calls =
      agent_usage
      |> Enum.flat_map(fn {name, _usage} ->
        CostTracker.get_call_history(team_id, name)
      end)

    agent_costs =
      agent_usage
      |> Enum.map(fn {name, usage} ->
        %{
          name: name,
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          total_tokens: usage.input_tokens + usage.output_tokens,
          cost: usage.cost,
          requests: usage.requests,
          last_model: usage.last_model
        }
      end)
      |> Enum.sort_by(& &1.total_tokens, :desc)

    # Model breakdown: aggregate across agents (reuse all_calls)
    model_costs =
      all_calls
      |> Enum.group_by(fn call -> call[:model] || "unknown" end)
      |> Enum.map(fn {model, calls} ->
        %{
          model: model,
          cost: calls |> Enum.map(fn c -> c[:cost] || 0 end) |> Enum.sum(),
          requests: length(calls)
        }
      end)
      |> Enum.sort_by(& &1.cost, :desc)

    # Total spent
    total_spent =
      agent_costs
      |> Enum.map(& &1.cost)
      |> Enum.sum()

    # Escalation events
    escalations = CostTracker.list_escalations(team_id)

    timeline = build_timeline(all_calls)

    socket
    |> assign(:agent_costs, agent_costs)
    |> assign(:model_costs, model_costs)
    |> assign(:budget, %{spent: total_spent, limit: budget_limit})
    |> assign(:escalations, escalations)
    |> assign(:timeline, timeline)
  end

  defp build_timeline([]), do: []

  defp build_timeline(calls) do
    timestamps =
      calls
      |> Enum.map(fn c -> c[:timestamp] end)
      |> Enum.reject(&is_nil/1)

    case timestamps do
      [] ->
        []

      ts ->
        min_t = ts |> Enum.min(DateTime)
        max_t = ts |> Enum.max(DateTime)
        span = max(DateTime.diff(max_t, min_t, :second), 1)
        bucket_count = 10
        bucket_size = max(div(span, bucket_count), 1)

        buckets =
          for i <- 0..(bucket_count - 1) do
            bucket_start = DateTime.add(min_t, i * bucket_size, :second)
            bucket_end = DateTime.add(min_t, (i + 1) * bucket_size, :second)

            cost =
              calls
              |> Enum.filter(fn c ->
                t = c[:timestamp]

                t && DateTime.compare(t, bucket_start) != :lt &&
                  DateTime.compare(t, bucket_end) == :lt
              end)
              |> Enum.map(fn c -> c[:cost] || 0 end)
              |> Enum.sum()

            %{
              start: bucket_start,
              end: bucket_end,
              cost: cost
            }
          end

        # Include anything at or after the last bucket_end in the last bucket
        last_bucket_end = DateTime.add(min_t, bucket_count * bucket_size, :second)

        overflow_cost =
          calls
          |> Enum.filter(fn c ->
            t = c[:timestamp]
            t && DateTime.compare(t, last_bucket_end) != :lt
          end)
          |> Enum.map(fn c -> c[:cost] || 0 end)
          |> Enum.sum()

        case List.last(buckets) do
          nil ->
            buckets

          last ->
            List.replace_at(buckets, -1, %{last | cost: last.cost + overflow_cost})
        end
    end
  end

  # --- Signal handlers ---

  def handle_info(%Jido.Signal{type: "agent.usage"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(
        %Jido.Signal{
          type: "agent.escalation",
          data: %{agent_name: agent_name, from_model: old_model, to_model: new_model}
        },
        socket
      ) do
    escalation = %{
      agent: agent_name,
      from: old_model,
      to: new_model,
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:escalations, Enum.take(socket.assigns.escalations ++ [escalation], -500))
     |> schedule_reload()}
  end

  def handle_info(%Jido.Signal{type: "team.task.completed"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(%Jido.Signal{type: "system.metrics.updated"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_cost_data, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_cost_data()}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp schedule_reload(socket) do
    if timer = socket.assigns[:reload_timer] do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :reload_cost_data, 500)
    assign(socket, :reload_timer, timer)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4" aria-live="polite">
      <%!-- Budget Utilization Gauge --%>
      <section aria-labelledby={"#{@id}-budget-heading"} class="card p-4">
        <div class="flex items-center justify-between mb-2">
          <h3 id={"#{@id}-budget-heading"} class="text-xs text-muted uppercase tracking-wider">
            Budget
          </h3>
          <span class="text-sm text-secondary font-mono">
            ${format_cost(@budget.spent)} / ${format_cost(@budget.limit)} spent
            <span class={"ml-1 font-semibold #{budget_pct_color(@budget)}"}>
              ({budget_percentage(@budget)}%)
            </span>
          </span>
        </div>
        <div
          class="w-full bg-surface-3 rounded-full h-3"
          role="progressbar"
          aria-valuenow={budget_percentage(@budget)}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-label={"Budget: #{budget_percentage(@budget)}% used"}
        >
          <div
            class={"h-3 rounded-full transition-all duration-500 ease-out #{budget_bar_color(@budget)}"}
            style={"width: #{min(budget_percentage(@budget), 100)}%"}
          >
          </div>
        </div>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%!-- Per-Agent Token Usage --%>
        <section aria-labelledby={"#{@id}-agents-heading"} class="card p-4">
          <h3 id={"#{@id}-agents-heading"} class="text-xs text-muted uppercase tracking-wider mb-3">
            Agent Token Usage
          </h3>
          <div :if={@agent_costs == []} class="text-xs text-muted text-center py-4">
            No agent data yet
          </div>
          <div :for={agent <- @agent_costs} class="mb-3 last:mb-0">
            <div class="flex items-center justify-between text-xs mb-1">
              <span class="text-secondary font-medium truncate max-w-[50%]">{agent.name}</span>
              <span class="text-muted font-mono">{format_number(agent.total_tokens)} tok</span>
            </div>
            <div
              class="w-full bg-surface-3 rounded-full h-2 flex overflow-hidden"
              role="progressbar"
              aria-valuenow={token_bar_pct(agent.total_tokens, @agent_costs)}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-label={"#{agent.name}: #{format_number(agent.total_tokens)} tokens"}
            >
              <div
                class="h-2 rounded-l-full opacity-60"
                style={"width: #{token_bar_pct(agent.input_tokens, @agent_costs)}%; background-color: #{agent_color(agent.name)}"}
              >
              </div>
              <div
                class="h-2 rounded-r-full"
                style={"width: #{token_bar_pct(agent.output_tokens, @agent_costs)}%; background-color: #{agent_color(agent.name)}"}
              >
              </div>
            </div>
            <div class="flex items-center gap-3 mt-1">
              <span class="text-[10px] text-muted">
                in: {format_number(agent.input_tokens)}
              </span>
              <span class="text-[10px] text-muted">
                out: {format_number(agent.output_tokens)}
              </span>
              <span class="text-[10px] text-green-400/70 ml-auto font-mono">
                ${format_cost(agent.cost)}
              </span>
            </div>
          </div>
        </section>

        <%!-- Per-Model Cost Breakdown --%>
        <section aria-labelledby={"#{@id}-models-heading"} class="card p-4">
          <h3
            id={"#{@id}-models-heading"}
            class="text-xs text-muted uppercase tracking-wider mb-3"
          >
            Model Costs
          </h3>
          <div :if={@model_costs == []} class="text-xs text-muted text-center py-4">
            No model data yet
          </div>
          <div class="grid grid-cols-1 gap-2">
            <div
              :for={model <- @model_costs}
              class="bg-surface-3 border border-subtle rounded-lg p-3"
            >
              <div class="flex items-start justify-between">
                <span class={"text-xs font-mono font-medium #{model_accent(model.model)}"}>
                  {short_model(model.model)}
                </span>
                <span class="text-sm font-bold text-green-400 font-mono">
                  ${format_cost(model.cost)}
                </span>
              </div>
              <span class="text-[10px] text-muted">{model.requests} requests</span>
            </div>
          </div>
        </section>
      </div>

      <%!-- Cost Timeline --%>
      <section :if={@timeline != []} aria-labelledby={"#{@id}-timeline-heading"} class="card p-4">
        <h3 id={"#{@id}-timeline-heading"} class="text-xs text-muted uppercase tracking-wider mb-3">
          Cost Over Time
        </h3>
        <div class="flex items-end gap-1 h-20" role="img" aria-label="Cost over time bar chart">
          <div
            :for={bucket <- @timeline}
            class="flex-1 bg-violet-500/80 hover:bg-violet-400 rounded-t transition-colors cursor-default group relative"
            style={"height: #{timeline_bar_height(bucket.cost, @timeline)}%"}
          >
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-1 hidden group-hover:block bg-surface-3 border border-default rounded px-2 py-1 text-[10px] text-secondary whitespace-nowrap z-10">
              <div class="font-mono">${format_cost(bucket.cost)}</div>
              <div class="text-muted">{format_time(bucket.start)} - {format_time(bucket.end)}</div>
            </div>
          </div>
        </div>
        <div class="flex justify-between mt-1">
          <span class="text-[10px] text-muted">{format_time(List.first(@timeline).start)}</span>
          <span class="text-[10px] text-muted">{format_time(List.last(@timeline).end)}</span>
        </div>
      </section>

      <%!-- Escalation Events --%>
      <section
        :if={@escalations != []}
        aria-labelledby={"#{@id}-escalations-heading"}
        class="card p-4"
      >
        <h3
          id={"#{@id}-escalations-heading"}
          class="text-xs text-muted uppercase tracking-wider mb-3"
        >
          Escalations
        </h3>
        <div class="space-y-2">
          <div :for={esc <- @escalations} class="border-l-2 border-amber-400 pl-3 py-1">
            <div class="flex items-center gap-2">
              <span class="text-xs text-amber-400 font-medium">{esc.agent}</span>
              <span class="text-[10px] text-muted">{format_datetime(esc.at)}</span>
            </div>
            <div class="text-xs text-secondary mt-0.5">
              <span class="font-mono text-muted">{short_model(esc.from)}</span>
              <span class="text-amber-400 mx-1">&rarr;</span>
              <span class="font-mono text-amber-300">{short_model(esc.to)}</span>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # --- Helpers ---

  defp agent_color(agent_name), do: LoomkinWeb.AgentColors.agent_color(agent_name)

  defp token_bar_pct(_tokens, []), do: 0

  defp token_bar_pct(tokens, agent_costs) do
    max_total = agent_costs |> Enum.map(& &1.total_tokens) |> Enum.max(fn -> 1 end)
    if max_total > 0, do: Float.round(tokens / max_total * 100, 1), else: 0
  end

  defp timeline_bar_height(_cost, []), do: 0

  defp timeline_bar_height(cost, timeline) do
    max_cost = timeline |> Enum.map(& &1.cost) |> Enum.max(fn -> 0 end)

    if max_cost > 0 do
      max(round(cost / max_cost * 100), 2)
    else
      2
    end
  end

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

  defp model_accent(model) do
    cond do
      String.contains?(model, "opus") -> "text-purple-400"
      String.contains?(model, "sonnet") -> "text-blue-400"
      String.contains?(model, "haiku") -> "text-teal-400"
      String.contains?(model, "glm") -> "text-emerald-400"
      true -> "text-violet-400"
    end
  end

  defp short_model(nil), do: "unknown"

  defp short_model(model) when is_binary(model) do
    model
    |> String.split(":")
    |> List.last()
  end

  defp format_cost(cost) when is_number(cost), do: :erlang.float_to_binary(cost / 1, decimals: 4)
  defp format_cost(_), do: "0.0000"

  defp format_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_number(n) when is_number(n), do: to_string(trunc(n))
  defp format_number(_), do: "0"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp format_time(_), do: ""

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_datetime(_), do: ""
end
