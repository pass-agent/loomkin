defmodule LoomkinWeb.CostDashboardLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Telemetry.Metrics

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Loomkin.Signals.subscribe("system.metrics.updated")
    end

    {:ok, assign_metrics(socket)}
  end

  def handle_info({:signal, %Jido.Signal{} = sig}, socket), do: handle_info(sig, socket)

  def handle_info(%Jido.Signal{type: "system.metrics.updated"}, socket) do
    {:noreply, assign_metrics(socket)}
  end

  defp assign_metrics(socket) do
    assign(socket,
      page_title: "Loomkin - Cost Dashboard",
      global: Metrics.global_metrics(),
      sessions: Metrics.all_sessions(),
      models: Metrics.model_breakdown(),
      tools: Metrics.tool_stats()
    )
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 text-primary" aria-live="polite">
      <div class="max-w-6xl mx-auto px-4 md:px-6 py-6 animate-fade-in space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-brand">Cost Dashboard</h1>
            <p class="text-sm text-muted mt-1">Real-time telemetry and usage metrics</p>
          </div>
          <.link navigate="/" class="text-sm text-brand hover:text-brand/80 transition-colors">
            Back to Workspace
          </.link>
        </div>

        <%!-- Global Summary Cards --%>
        <section aria-labelledby="summary-heading">
          <h2 id="summary-heading" class="sr-only">Summary</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div class="card-elevated p-4">
              <p class="text-xs text-muted uppercase tracking-wider">Total Cost</p>
              <p class="text-2xl font-bold text-green-400 mt-1">
                ${format_cost(@global.total_cost)}
              </p>
            </div>
            <div class="card-elevated p-4">
              <p class="text-xs text-muted uppercase tracking-wider">Total Tokens</p>
              <p class="text-2xl font-bold text-blue-400 mt-1">
                {format_number(@global.total_tokens)}
              </p>
            </div>
            <div class="card-elevated p-4">
              <p class="text-xs text-muted uppercase tracking-wider">LLM Requests</p>
              <p class="text-2xl font-bold text-purple-400 mt-1">
                {format_number(@global.total_requests)}
              </p>
            </div>
          </div>
        </section>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Session Cost Table --%>
          <section aria-labelledby="sessions-heading" class="card">
            <div class="px-5 py-3 border-b border-subtle">
              <h2 id="sessions-heading" class="text-sm font-semibold text-primary">Sessions</h2>
            </div>
            <div class="overflow-auto max-h-80">
              <table class="w-full text-xs" aria-describedby="sessions-heading">
                <thead>
                  <tr class="text-muted border-b border-subtle">
                    <th scope="col" class="text-left px-4 py-2">Session</th>
                    <th scope="col" class="text-right px-4 py-2">Tokens</th>
                    <th scope="col" class="text-right px-4 py-2">Cost</th>
                    <th scope="col" class="text-right px-4 py-2">Requests</th>
                    <th scope="col" class="text-right px-4 py-2">Tools</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={s <- @sessions}
                    class="border-b border-subtle hover:bg-surface-1/50 transition-colors"
                  >
                    <td class="px-4 py-2 font-mono text-brand">
                      {short_id(s.session_id)}
                    </td>
                    <td class="px-4 py-2 text-right text-secondary">
                      {format_number(s.prompt_tokens + s.completion_tokens)}
                    </td>
                    <td class="px-4 py-2 text-right text-green-400">
                      ${format_cost(s.cost_usd)}
                    </td>
                    <td class="px-4 py-2 text-right text-secondary">
                      {s.llm_requests}
                    </td>
                    <td class="px-4 py-2 text-right text-secondary">
                      {s.tool_calls}
                    </td>
                  </tr>
                  <tr :if={@sessions == []}>
                    <td colspan="5" class="px-4 py-6 text-center text-muted">
                      No session data yet
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <%!-- Model Usage Breakdown --%>
          <section aria-labelledby="model-usage-heading" class="card">
            <div class="px-5 py-3 border-b border-subtle">
              <h2 id="model-usage-heading" class="text-sm font-semibold text-primary">
                Model Usage
              </h2>
            </div>
            <div class="p-4">
              <div :if={@models == %{}} class="text-center text-muted text-xs py-6">
                No model data yet
              </div>
              <div :for={{model, count} <- Enum.sort_by(@models, fn {_, c} -> -c end)} class="mb-3">
                <div class="flex items-center justify-between text-xs mb-1">
                  <span class="text-secondary font-mono">{model}</span>
                  <span class="text-muted">{count} requests</span>
                </div>
                <div
                  class="w-full bg-surface-3 rounded-full h-2"
                  role="progressbar"
                  aria-valuenow={bar_width(count, @models)}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-label={"#{model}: #{count} requests"}
                >
                  <div
                    class="bg-violet-500 h-2 rounded-full"
                    style={"width: #{bar_width(count, @models)}%"}
                  >
                  </div>
                </div>
              </div>
            </div>
          </section>

          <%!-- Tool Execution Stats --%>
          <section aria-labelledby="tools-heading" class="card lg:col-span-2">
            <div class="px-5 py-3 border-b border-subtle">
              <h2 id="tools-heading" class="text-sm font-semibold text-primary">Tool Execution</h2>
            </div>
            <div class="overflow-auto max-h-64">
              <table class="w-full text-xs" aria-describedby="tools-heading">
                <thead>
                  <tr class="text-muted border-b border-subtle">
                    <th scope="col" class="text-left px-4 py-2">Tool</th>
                    <th scope="col" class="text-right px-4 py-2">Calls</th>
                    <th scope="col" class="text-right px-4 py-2">Success Rate</th>
                    <th scope="col" class="text-right px-4 py-2">Avg Duration</th>
                    <th scope="col" class="text-right px-4 py-2">Total Time</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{name, stats} <- Enum.sort_by(@tools, fn {_, s} -> -s.count end)}
                    class="border-b border-subtle hover:bg-surface-1/50 transition-colors"
                  >
                    <td class="px-4 py-2 font-mono text-yellow-400">{name}</td>
                    <td class="px-4 py-2 text-right text-secondary">{stats.count}</td>
                    <td class="px-4 py-2 text-right">
                      <span class={success_color(stats.successes, stats.count)}>
                        {success_pct(stats.successes, stats.count)}%
                        <span class="sr-only">
                          ({success_label(stats.successes, stats.count)})
                        </span>
                      </span>
                    </td>
                    <td class="px-4 py-2 text-right text-secondary">
                      {avg_duration(stats)}ms
                    </td>
                    <td class="px-4 py-2 text-right text-muted">
                      {format_number(stats.total_duration_ms)}ms
                    </td>
                  </tr>
                  <tr :if={@tools == %{}}>
                    <td colspan="5" class="px-4 py-6 text-center text-muted">
                      No tool data yet
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp format_cost(cost) when is_number(cost), do: :erlang.float_to_binary(cost / 1, decimals: 4)
  defp format_cost(_), do: "0.0000"

  defp format_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_number(n) when is_number(n), do: to_string(trunc(n))
  defp format_number(_), do: "0"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "?"

  defp bar_width(count, models) do
    max_count = models |> Map.values() |> Enum.max(fn -> 1 end)
    if max_count > 0, do: round(count / max_count * 100), else: 0
  end

  defp success_pct(successes, total) when total > 0, do: round(successes / total * 100)
  defp success_pct(_, _), do: 0

  defp success_color(successes, total) when total > 0 do
    pct = successes / total * 100

    cond do
      pct >= 90 -> "text-green-400"
      pct >= 70 -> "text-yellow-400"
      true -> "text-red-400"
    end
  end

  defp success_color(_, _), do: "text-muted"

  defp success_label(successes, total) when total > 0 do
    pct = successes / total * 100

    cond do
      pct >= 90 -> "good"
      pct >= 70 -> "warning"
      true -> "poor"
    end
  end

  defp success_label(_, _), do: "no data"

  defp avg_duration(%{count: c, total_duration_ms: t}) when c > 0, do: round(t / c)
  defp avg_duration(_), do: 0
end
