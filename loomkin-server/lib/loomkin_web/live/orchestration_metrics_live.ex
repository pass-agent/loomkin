defmodule LoomkinWeb.OrchestrationMetricsLive do
  @moduledoc """
  Aggregated dashboard for `Loomkin.Orchestration.Metrics`.

  Surfaces the four key roll-ups the orchestration framework cares about:

    * pass rate per gate
    * iteration distribution (how many attempts a gate needed)
    * per-model pass rate
    * escalation count

  Visuals reuse the project's Cozy Studio tokens (see `assets/css/app.css`)
  and the existing `.card` / `.badge` utility classes so this page stays
  visually consistent with `OrchestrationIndexLive` and
  `OrchestrationKnowledgeLive`.

  Color is never the only signal — pass rates are also rendered as text
  alongside their colored badges, and bar charts have explicit numeric
  labels. Each `<section>` is `aria-labelledby` a visible or sr-only heading.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Orchestration.Metrics

  # Windows the filter form offers. Atom is the form value; the second
  # element is the human label; the third is the number of seconds back
  # from "now" (nil means all-time).
  @windows [
    {:hour, "Last hour", 3_600},
    {:day, "Last 24 hours", 86_400},
    {:week, "Last 7 days", 7 * 86_400},
    {:all, "All time", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Orchestration metrics")
     |> assign(:windows, @windows)
     |> assign(:since_key, :day)
     |> load_metrics()}
  end

  defp load_metrics(socket) do
    since_key = socket.assigns.since_key
    since_dt = since_for(since_key)

    filters = if since_dt, do: %{since: since_dt}, else: %{}

    aggregate = Metrics.aggregate(filters)
    events = Metrics.list(filters)

    socket
    |> assign(:aggregate, aggregate)
    |> assign(:total_events, length(events))
    |> assign(:overall_pass_rate, overall_pass_rate(aggregate.pass_rate_by_gate))
    |> assign(:distinct_models, map_size(aggregate.per_model_pass_rate))
  end

  defp since_for(key) do
    case Enum.find(@windows, fn {k, _, _} -> k == key end) do
      {_, _, nil} -> nil
      {_, _, secs} -> DateTime.add(DateTime.utc_now(), -secs, :second)
      nil -> nil
    end
  end

  defp overall_pass_rate(by_gate) when map_size(by_gate) == 0, do: nil

  defp overall_pass_rate(by_gate) do
    values = by_gate |> Map.values() |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"since" => since}}, socket) do
    key = parse_since(since)

    {:noreply,
     socket
     |> assign(:since_key, key)
     |> load_metrics()}
  end

  defp parse_since(s) when is_binary(s) do
    atom = String.to_atom(s)
    if Enum.any?(@windows, fn {k, _, _} -> k == atom end), do: atom, else: :day
  end

  defp parse_since(_), do: :day

  # ----------------------------------------------------------- presentation

  defp rate_badge(nil), do: {"badge", "n/a"}

  defp rate_badge(rate) when is_float(rate) or is_integer(rate) do
    pct = round(rate * 100)

    cond do
      rate >= 0.9 -> {"badge badge-success", "#{pct}% pass"}
      rate >= 0.7 -> {"badge badge-warning", "#{pct}% pass"}
      true -> {"badge badge-danger", "#{pct}% pass"}
    end
  end

  defp format_rate(nil), do: "—"

  defp format_rate(rate) when is_float(rate) or is_integer(rate),
    do: "#{round(rate * 100)}%"

  defp bar_width(_value, 0), do: "0%"

  defp bar_width(value, max) when is_integer(value) and is_integer(max) and max > 0,
    do: "#{round(value / max * 100)}%"

  defp bar_width(value, max) when is_number(value) and is_number(max) and max > 0,
    do: "#{round(value / max * 100)}%"

  defp bar_width(_, _), do: "0%"

  defp gate_label(nil), do: "(unknown)"
  defp gate_label(""), do: "(unknown)"
  defp gate_label(g) when is_binary(g), do: g
  defp gate_label(g) when is_atom(g), do: Atom.to_string(g)

  defp empty?(%{
         pass_rate_by_gate: pg,
         iteration_distribution: id,
         per_model_pass_rate: pm,
         escalation_count: ec
       }) do
    map_size(pg) == 0 and map_size(id) == 0 and map_size(pm) == 0 and ec == 0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      class="min-h-screen px-6 py-10"
      style="background: var(--surface-0); color: var(--text-primary);"
      aria-labelledby="orch-metrics-h"
    >
      <div class="max-w-5xl mx-auto">
        <header class="mb-8">
          <p class="text-xs font-mono mb-2" style="color: var(--text-muted);">
            <.link navigate={~p"/orchestration"} class="hover:underline">← orchestration</.link>
            <span class="mx-1">·</span>
            <.link navigate={~p"/orchestration/knowledge"} class="hover:underline">knowledge</.link>
          </p>
          <h1 id="orch-metrics-h" class="text-2xl font-semibold" style="color: var(--text-primary);">
            Orchestration metrics
          </h1>
          <p class="text-sm mt-1" style="color: var(--text-secondary);">
            Pass rates, iteration counts, per-model performance, and escalation totals derived from <code>orchestration_phase_metrics</code>.
          </p>
        </header>

        <section class="card p-4 mb-6" aria-labelledby="orch-metrics-filter-h">
          <h2 id="orch-metrics-filter-h" class="sr-only">Filters</h2>
          <form phx-change="filter" class="flex flex-wrap items-end gap-4">
            <label class="flex flex-col gap-1 text-xs font-mono" style="color: var(--text-muted);">
              window
              <select
                name="filters[since]"
                class="rounded px-2 py-1.5 text-sm"
                style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
              >
                <option
                  :for={{key, label, _} <- @windows}
                  value={Atom.to_string(key)}
                  selected={@since_key == key}
                >
                  {label}
                </option>
              </select>
            </label>
          </form>
        </section>

        <section class="mb-8" aria-labelledby="orch-metrics-headline-h">
          <h2 id="orch-metrics-headline-h" class="sr-only">Headline stats</h2>
          <ul role="list" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            <li class="card p-4">
              <p class="text-xs font-mono uppercase tracking-wider" style="color: var(--text-muted);">
                Total events
              </p>
              <p class="mt-2 text-3xl font-semibold" style="color: var(--text-brand);">
                {@total_events}
              </p>
              <p class="text-xs mt-1" style="color: var(--text-secondary);">
                phase_metric rows in window
              </p>
            </li>

            <li class="card p-4">
              <p class="text-xs font-mono uppercase tracking-wider" style="color: var(--text-muted);">
                Escalations
              </p>
              <p
                class="mt-2 text-3xl font-semibold"
                style={
                  if @aggregate.escalation_count > 0,
                    do: "color: var(--accent-rose);",
                    else: "color: var(--text-brand);"
                }
              >
                {@aggregate.escalation_count}
              </p>
              <p class="text-xs mt-1 flex items-center gap-2" style="color: var(--text-secondary);">
                <span
                  :if={@aggregate.escalation_count > 0}
                  class="badge badge-danger"
                  aria-label="elevated escalation count"
                >
                  attention
                </span>
                <span>handed to humans</span>
              </p>
            </li>

            <li class="card p-4">
              <p class="text-xs font-mono uppercase tracking-wider" style="color: var(--text-muted);">
                Overall gate pass rate
              </p>
              <p class="mt-2 text-3xl font-semibold" style="color: var(--text-brand);">
                {format_rate(@overall_pass_rate)}
              </p>
              <p class="text-xs mt-1" style="color: var(--text-secondary);">
                avg across {map_size(@aggregate.pass_rate_by_gate)} gate(s)
              </p>
            </li>

            <li class="card p-4">
              <p class="text-xs font-mono uppercase tracking-wider" style="color: var(--text-muted);">
                Distinct models
              </p>
              <p class="mt-2 text-3xl font-semibold" style="color: var(--text-brand);">
                {@distinct_models}
              </p>
              <p class="text-xs mt-1" style="color: var(--text-secondary);">
                producing verdicts in window
              </p>
            </li>
          </ul>
        </section>

        <p
          :if={empty?(@aggregate)}
          class="card p-6 text-sm mb-8"
          style="color: var(--text-muted);"
        >
          No orchestration events recorded yet.
        </p>

        <section
          :if={not empty?(@aggregate)}
          class="card p-6 mb-6"
          aria-labelledby="orch-metrics-gates-h"
        >
          <h2
            id="orch-metrics-gates-h"
            class="text-lg font-medium mb-4"
            style="color: var(--text-primary);"
          >
            Pass rate per gate
          </h2>
          <p
            :if={map_size(@aggregate.pass_rate_by_gate) == 0}
            class="text-sm"
            style="color: var(--text-muted);"
          >
            No gate verdicts in this window.
          </p>
          <table
            :if={map_size(@aggregate.pass_rate_by_gate) > 0}
            class="w-full text-sm"
          >
            <caption class="sr-only">Pass rate per gate</caption>
            <thead>
              <tr
                style="color: var(--text-muted);"
                class="text-xs font-mono uppercase tracking-wider text-left"
              >
                <th scope="col" class="pb-2 pr-4">Gate</th>
                <th scope="col" class="pb-2 pr-4">Rate</th>
                <th scope="col" class="pb-2 w-1/2">Distribution</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={
                {gate, rate} <- Enum.sort_by(@aggregate.pass_rate_by_gate, fn {g, _} -> g end)
              }>
                <th
                  scope="row"
                  class="py-2 pr-4 font-medium align-top"
                  style="color: var(--text-primary);"
                >
                  {gate_label(gate)}
                </th>
                <td class="py-2 pr-4 align-top">
                  <% {cls, lbl} = rate_badge(rate) %>
                  <span class={cls}>{lbl}</span>
                </td>
                <td class="py-2 align-top">
                  <div
                    class="w-full h-2 rounded overflow-hidden"
                    style="background: var(--surface-2);"
                    role="img"
                    aria-label={"pass rate " <> format_rate(rate)}
                  >
                    <div
                      class="h-full"
                      style={"width: #{if rate, do: "#{round(rate * 100)}%", else: "0%"}; background: var(--brand);"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section
          :if={not empty?(@aggregate)}
          class="card p-6 mb-6"
          aria-labelledby="orch-metrics-iters-h"
        >
          <h2
            id="orch-metrics-iters-h"
            class="text-lg font-medium mb-4"
            style="color: var(--text-primary);"
          >
            Iteration distribution
          </h2>
          <p
            :if={map_size(@aggregate.iteration_distribution) == 0}
            class="text-sm"
            style="color: var(--text-muted);"
          >
            No iteration data in this window.
          </p>
          <% iters = Enum.sort_by(@aggregate.iteration_distribution, fn {i, _} -> i end)
          iter_max = iters |> Enum.map(fn {_, c} -> c end) |> Enum.max(fn -> 0 end) %>
          <ul :if={iters != []} role="list" class="flex flex-col gap-2">
            <li :for={{iteration, count} <- iters} class="flex items-center gap-3">
              <span
                class="text-xs font-mono w-24 shrink-0"
                style="color: var(--text-secondary);"
              >
                {iteration} attempt{if iteration == 1, do: "", else: "s"}
              </span>
              <div
                class="flex-1 h-3 rounded overflow-hidden"
                style="background: var(--surface-2);"
                role="img"
                aria-label={"#{count} occurrences at #{iteration} attempts"}
              >
                <div
                  class="h-full"
                  style={"width: #{bar_width(count, iter_max)}; background: var(--brand);"}
                >
                </div>
              </div>
              <span
                class="text-sm font-medium w-12 text-right"
                style="color: var(--text-primary);"
              >
                {count}
              </span>
            </li>
          </ul>
        </section>

        <section :if={not empty?(@aggregate)} class="card p-6" aria-labelledby="orch-metrics-models-h">
          <h2
            id="orch-metrics-models-h"
            class="text-lg font-medium mb-4"
            style="color: var(--text-primary);"
          >
            Per-model pass rate
          </h2>
          <p
            :if={map_size(@aggregate.per_model_pass_rate) == 0}
            class="text-sm"
            style="color: var(--text-muted);"
          >
            No model attribution in this window.
          </p>
          <table
            :if={map_size(@aggregate.per_model_pass_rate) > 0}
            class="w-full text-sm"
          >
            <caption class="sr-only">Pass rate per model</caption>
            <thead>
              <tr
                style="color: var(--text-muted);"
                class="text-xs font-mono uppercase tracking-wider text-left"
              >
                <th scope="col" class="pb-2 pr-4">Model</th>
                <th scope="col" class="pb-2 pr-4">Rate</th>
                <th scope="col" class="pb-2">Numeric</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={
                {model, rate} <- Enum.sort_by(@aggregate.per_model_pass_rate, fn {m, _} -> m end)
              }>
                <th
                  scope="row"
                  class="py-2 pr-4 font-medium align-top"
                  style="color: var(--text-primary);"
                >
                  <code>{model}</code>
                </th>
                <td class="py-2 pr-4 align-top">
                  <% {cls, lbl} = rate_badge(rate) %>
                  <span class={cls}>{lbl}</span>
                </td>
                <td class="py-2 align-top text-xs font-mono" style="color: var(--text-secondary);">
                  {format_rate(rate)}
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </main>
    """
  end
end
