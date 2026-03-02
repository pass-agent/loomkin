defmodule LoomkinWeb.CostDashboardLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Telemetry.Metrics

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "telemetry:updates")
    end

    {:ok, assign_metrics(socket)}
  end

  def handle_info(:metrics_updated, socket) do
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
    <div class="min-h-screen bg-gray-950 text-gray-100 p-6">
      <div class="max-w-7xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-violet-400">Cost Dashboard</h1>
            <p class="text-sm text-gray-500 mt-1">Real-time telemetry and usage metrics</p>
          </div>
          <a href="/" class="text-sm text-violet-400 hover:text-violet-300">
            Back to Workspace
          </a>
        </div>

        <%!-- Global Summary Cards --%>
        <div class="grid grid-cols-3 gap-4 mb-8">
          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
            <p class="text-xs text-gray-500 uppercase tracking-wider">Total Cost</p>
            <p class="text-2xl font-bold text-green-400 mt-1">
              ${format_cost(@global.total_cost)}
            </p>
          </div>
          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
            <p class="text-xs text-gray-500 uppercase tracking-wider">Total Tokens</p>
            <p class="text-2xl font-bold text-blue-400 mt-1">
              {format_number(@global.total_tokens)}
            </p>
          </div>
          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
            <p class="text-xs text-gray-500 uppercase tracking-wider">LLM Requests</p>
            <p class="text-2xl font-bold text-purple-400 mt-1">
              {format_number(@global.total_requests)}
            </p>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-6">
          <%!-- Session Cost Table --%>
          <div class="bg-gray-900 border border-gray-800 rounded-lg">
            <div class="px-4 py-3 border-b border-gray-800">
              <h2 class="text-sm font-semibold text-gray-300">Sessions</h2>
            </div>
            <div class="overflow-auto max-h-80">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-gray-500 border-b border-gray-800">
                    <th class="text-left px-4 py-2">Session</th>
                    <th class="text-right px-4 py-2">Tokens</th>
                    <th class="text-right px-4 py-2">Cost</th>
                    <th class="text-right px-4 py-2">Requests</th>
                    <th class="text-right px-4 py-2">Tools</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={s <- @sessions}
                    class="border-b border-gray-800/50 hover:bg-gray-800/30"
                  >
                    <td class="px-4 py-2 font-mono text-violet-400">
                      {short_id(s.session_id)}
                    </td>
                    <td class="px-4 py-2 text-right text-gray-300">
                      {format_number(s.prompt_tokens + s.completion_tokens)}
                    </td>
                    <td class="px-4 py-2 text-right text-green-400">
                      ${format_cost(s.cost_usd)}
                    </td>
                    <td class="px-4 py-2 text-right text-gray-300">
                      {s.llm_requests}
                    </td>
                    <td class="px-4 py-2 text-right text-gray-300">
                      {s.tool_calls}
                    </td>
                  </tr>
                  <tr :if={@sessions == []}>
                    <td colspan="5" class="px-4 py-6 text-center text-gray-600">
                      No session data yet
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Model Usage Breakdown --%>
          <div class="bg-gray-900 border border-gray-800 rounded-lg">
            <div class="px-4 py-3 border-b border-gray-800">
              <h2 class="text-sm font-semibold text-gray-300">Model Usage</h2>
            </div>
            <div class="p-4">
              <div :if={@models == %{}} class="text-center text-gray-600 text-xs py-6">
                No model data yet
              </div>
              <div :for={{model, count} <- Enum.sort_by(@models, fn {_, c} -> -c end)} class="mb-3">
                <div class="flex items-center justify-between text-xs mb-1">
                  <span class="text-gray-300 font-mono">{model}</span>
                  <span class="text-gray-500">{count} requests</span>
                </div>
                <div class="w-full bg-gray-800 rounded-full h-2">
                  <div
                    class="bg-violet-500 h-2 rounded-full"
                    style={"width: #{bar_width(count, @models)}%"}
                  >
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Tool Execution Stats --%>
          <div class="bg-gray-900 border border-gray-800 rounded-lg col-span-2">
            <div class="px-4 py-3 border-b border-gray-800">
              <h2 class="text-sm font-semibold text-gray-300">Tool Execution</h2>
            </div>
            <div class="overflow-auto max-h-64">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-gray-500 border-b border-gray-800">
                    <th class="text-left px-4 py-2">Tool</th>
                    <th class="text-right px-4 py-2">Calls</th>
                    <th class="text-right px-4 py-2">Success Rate</th>
                    <th class="text-right px-4 py-2">Avg Duration</th>
                    <th class="text-right px-4 py-2">Total Time</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{name, stats} <- Enum.sort_by(@tools, fn {_, s} -> -s.count end)}
                    class="border-b border-gray-800/50 hover:bg-gray-800/30"
                  >
                    <td class="px-4 py-2 font-mono text-yellow-400">{name}</td>
                    <td class="px-4 py-2 text-right text-gray-300">{stats.count}</td>
                    <td class="px-4 py-2 text-right">
                      <span class={success_color(stats.successes, stats.count)}>
                        {success_pct(stats.successes, stats.count)}%
                      </span>
                    </td>
                    <td class="px-4 py-2 text-right text-gray-300">
                      {avg_duration(stats)}ms
                    </td>
                    <td class="px-4 py-2 text-right text-gray-500">
                      {format_number(stats.total_duration_ms)}ms
                    </td>
                  </tr>
                  <tr :if={@tools == %{}}>
                    <td colspan="5" class="px-4 py-6 text-center text-gray-600">
                      No tool data yet
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
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

  defp success_color(_, _), do: "text-gray-500"

  defp avg_duration(%{count: c, total_duration_ms: t}) when c > 0, do: round(t / c)
  defp avg_duration(_), do: 0
end
