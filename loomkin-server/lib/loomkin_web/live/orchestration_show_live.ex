defmodule LoomkinWeb.OrchestrationShowLive do
  @moduledoc """
  Per-epic detail view. Shows the 9-phase progress bar, the work-unit list,
  and the gate verdict table.

  Subscribes to `orchestration.epic` and `orchestration.work_unit` PubSub
  topics and re-queries the DB on every change. Live work-unit events fill
  a per-unit timeline.

  Styling: Cozy Studio tokens + existing `.card` / `.badge` / `.loom-btn-*`.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Orchestration
  alias Loomkin.Orchestration.Context
  alias Loomkin.Orchestration.PRShepherd

  @epic_topic "orchestration.epic"
  @wu_topic "orchestration.work_unit"
  @shepherd_topic "orchestration.pr_shepherd"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @epic_topic)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @wu_topic)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @shepherd_topic)
    end

    case Context.get_epic(id) do
      nil ->
        {:ok, push_navigate(socket, to: "/orchestration")}

      epic ->
        {:ok,
         socket
         |> assign(:epic, epic)
         |> assign(:phase_list, Orchestration.phases())
         |> assign(:work_units, Context.list_work_units(id))
         |> assign(:gate_results, Context.list_gate_results(id))
         |> assign(:wu_events, %{})
         |> assign(:wu_diffs, %{})
         |> assign(:pr_ref, pr_ref_for_epic(epic))
         |> assign(:shepherd_status, shepherd_status_for(epic))
         |> assign(:page_title, "Epic " <> epic.title)}
    end
  end

  @impl true
  def handle_info({@epic_topic, %{epic_id: id}}, %{assigns: %{epic: %{id: id}}} = socket) do
    {:noreply,
     socket
     |> assign(:epic, Context.get_epic(id))
     |> assign(:work_units, Context.list_work_units(id))
     |> assign(:gate_results, Context.list_gate_results(id))}
  end

  def handle_info(
        {@wu_topic, %{work_unit_id: wu_id, event: :diff} = payload},
        socket
      ) do
    summary = %{
      sha: payload[:sha],
      stats: payload[:stats] || %{additions: 0, deletions: 0, files: 0},
      files: payload[:files] || [],
      patch_excerpt: payload[:patch_excerpt] || ""
    }

    diffs = Map.put(socket.assigns.wu_diffs, wu_id, summary)
    {:noreply, assign(socket, :wu_diffs, diffs)}
  end

  def handle_info({@wu_topic, %{work_unit_id: wu_id, event: ev}}, socket) do
    events = Map.update(socket.assigns.wu_events, wu_id, [ev], &[ev | &1])
    {:noreply, assign(socket, :wu_events, events)}
  end

  def handle_info({:pr_shepherd, pr_ref, _status, _meta}, socket) do
    if socket.assigns[:pr_ref] == pr_ref do
      {:noreply, assign(socket, :shepherd_status, shepherd_status_for(socket.assigns.epic))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("spawn_shepherd", _params, socket) do
    case socket.assigns[:pr_ref] do
      nil ->
        {:noreply, socket}

      pr_ref ->
        case PRShepherd.Supervisor.shepherd(pr_ref, epic_id: socket.assigns.epic.id) do
          {:ok, _pid} ->
            {:noreply, assign(socket, :shepherd_status, shepherd_status_for(socket.assigns.epic))}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  defp pr_ref_for_epic(%{metadata: %{} = meta}) do
    case Map.get(meta, "pr_ref") || Map.get(meta, :pr_ref) do
      [owner, repo, num] when is_binary(owner) and is_binary(repo) and is_integer(num) ->
        {owner, repo, num}

      {owner, repo, num} when is_binary(owner) and is_binary(repo) and is_integer(num) ->
        {owner, repo, num}

      %{"owner" => owner, "repo" => repo, "number" => num}
      when is_binary(owner) and is_binary(repo) and is_integer(num) ->
        {owner, repo, num}

      _ ->
        nil
    end
  end

  defp pr_ref_for_epic(_), do: nil

  defp shepherd_status_for(epic) do
    case pr_ref_for_epic(epic) do
      nil ->
        nil

      pr_ref ->
        case PRShepherd.Server.whereis(pr_ref) do
          nil -> nil
          pid -> safe_status(pid)
        end
    end
  end

  defp safe_status(pid) do
    PRShepherd.Server.status(pid)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp shepherd_badge(:ready), do: {"badge badge-success", "ready"}
  defp shepherd_badge(:failed), do: {"badge badge-danger", "failed"}
  defp shepherd_badge(:comments_pending), do: {"badge badge-warning", "comments pending"}
  defp shepherd_badge(:monitoring), do: {"badge", "monitoring"}
  defp shepherd_badge(other), do: {"badge", to_string(other)}

  defp phase_index(nil, _), do: -1

  defp phase_index(phase, list) when is_atom(phase),
    do: Enum.find_index(list, &(&1 == phase)) || -1

  defp phase_index(phase, list) when is_binary(phase),
    do: Enum.find_index(list, &(Atom.to_string(&1) == phase)) || -1

  defp status_badge(:closed), do: {"badge badge-success", "closed"}
  defp status_badge(:failed), do: {"badge badge-danger", "failed"}
  defp status_badge(:awaiting_human), do: {"badge badge-warning", "awaiting human"}
  defp status_badge(:in_progress), do: {"badge", "in progress"}
  defp status_badge(:pending), do: {"badge", "pending"}
  defp status_badge(:done), do: {"badge badge-success", "done"}
  defp status_badge(:implement), do: {"badge", "implement"}
  defp status_badge(:validate), do: {"badge", "validate"}
  defp status_badge(:adversarial_review), do: {"badge", "review"}
  defp status_badge(:commit), do: {"badge", "commit"}
  defp status_badge(other), do: {"badge", to_string(other)}

  defp verdict_badge(:pass), do: {"badge badge-success", "pass"}
  defp verdict_badge(:fail), do: {"badge badge-danger", "fail"}
  defp verdict_badge(other), do: {"badge", to_string(other)}

  @impl true
  def render(assigns) do
    ~H"""
    <main
      class="min-h-screen px-6 py-10"
      style="background: var(--surface-0); color: var(--text-primary);"
      aria-labelledby="orch-show-h"
    >
      <div class="max-w-5xl mx-auto">
        <header class="mb-8">
          <p class="text-xs font-mono mb-2" style="color: var(--text-muted);">
            <.link navigate={~p"/orchestration"} class="hover:underline">← all epics</.link>
          </p>
          <h1 id="orch-show-h" class="text-2xl font-semibold" style="color: var(--text-primary);">
            {@epic.title}
          </h1>
          <p class="mt-2 flex items-center gap-3 text-sm">
            <% {cls, lbl} = status_badge(@epic.status) %>
            <span class={cls}>{lbl}</span>
            <span :if={@epic.current_phase} style="color: var(--text-secondary);">
              phase: <strong style="color: var(--text-primary);">{@epic.current_phase}</strong>
            </span>
          </p>
        </header>

        <.live_component
          module={LoomkinWeb.OrchestrationPanelComponent}
          id={"panel-" <> @epic.id}
          epic={@epic}
        />

        <section class="card p-6 mb-6" aria-labelledby="orch-phases-h">
          <h2
            id="orch-phases-h"
            class="text-sm font-medium mb-3 uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            phases (9)
          </h2>
          <ol class="flex flex-wrap gap-2" role="list">
            <li
              :for={{ph, i} <- Enum.with_index(@phase_list)}
              class="flex items-center gap-2 px-3 py-1.5 rounded text-xs font-mono"
              style={
                if i <= phase_index(@epic.current_phase, @phase_list) do
                  "background: var(--brand-subtle); color: var(--text-brand); border: 1px solid var(--border-brand);"
                else
                  "background: var(--surface-1); color: var(--text-muted); border: 1px solid var(--border-subtle);"
                end
              }
            >
              <span
                class="block h-1.5 w-1.5 rounded-full"
                style={
                  if i <= phase_index(@epic.current_phase, @phase_list) do
                    "background: var(--brand);"
                  else
                    "background: var(--surface-3);"
                  end
                }
                aria-hidden="true"
              >
              </span>
              {ph}
            </li>
          </ol>
        </section>

        <section class="card p-6 mb-6" aria-labelledby="orch-spec-h">
          <h2
            id="orch-spec-h"
            class="text-sm font-medium mb-3 uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            spec
          </h2>
          <pre
            class="font-mono text-sm whitespace-pre-wrap rounded p-4"
            style="background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border-subtle);"
          >{@epic.spec}</pre>
        </section>

        <section class="card p-6 mb-6" aria-labelledby="orch-gates-h">
          <h2
            id="orch-gates-h"
            class="text-sm font-medium mb-3 uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            gate results
          </h2>
          <p
            :if={@gate_results == []}
            class="text-sm"
            style="color: var(--text-muted);"
          >
            No gate runs recorded yet.
          </p>
          <table :if={@gate_results != []} class="w-full text-sm">
            <thead>
              <tr style="color: var(--text-muted);">
                <th class="text-left py-2 pr-3 font-medium">kind</th>
                <th class="text-left py-2 pr-3 font-medium">iter</th>
                <th class="text-left py-2 pr-3 font-medium">verdict</th>
                <th class="text-left py-2 pr-3 font-medium">reviewers</th>
                <th class="text-left py-2 font-medium">at</th>
              </tr>
            </thead>
            <tbody style="color: var(--text-primary);">
              <tr
                :for={g <- @gate_results}
                class="border-t"
                style="border-color: var(--border-subtle);"
              >
                <td class="py-2 pr-3 font-mono text-xs">{g.kind}</td>
                <td class="py-2 pr-3">{g.iteration}</td>
                <td class="py-2 pr-3">
                  <% {vcls, vlbl} = verdict_badge(g.verdict) %>
                  <span class={vcls}>{vlbl}</span>
                </td>
                <td class="py-2 pr-3">{length(g.verdicts)}</td>
                <td class="py-2 text-xs" style="color: var(--text-muted);">
                  <time datetime={DateTime.to_iso8601(g.inserted_at)}>
                    {DateTime.to_iso8601(g.inserted_at)}
                  </time>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="card p-6" aria-labelledby="orch-wus-h">
          <h2
            id="orch-wus-h"
            class="text-sm font-medium mb-3 uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            work units
          </h2>
          <p
            :if={@work_units == []}
            class="text-sm"
            style="color: var(--text-muted);"
          >
            Work units are created during the <code>:decompose</code> phase.
          </p>
          <ul :if={@work_units != []} role="list" class="flex flex-col gap-3">
            <li
              :for={wu <- @work_units}
              class="rounded p-3"
              style="background: var(--surface-1); border: 1px solid var(--border-subtle);"
            >
              <div class="flex items-center justify-between gap-3">
                <strong style="color: var(--text-primary);">{wu.title}</strong>
                <% {wcls, wlbl} = status_badge(wu.status) %>
                <span class={wcls}>{wlbl}</span>
              </div>
              <% diff = Map.get(@wu_diffs, wu.id) %>
              <div
                :if={diff}
                class="mt-3 rounded p-2 text-xs font-mono"
                style="background: var(--surface-2); border: 1px solid var(--border-subtle);"
                aria-label="Diff summary for work unit"
              >
                <div class="flex items-center gap-3">
                  <span style="color: var(--text-brand);">
                    +{diff.stats.additions}
                  </span>
                  <span style="color: var(--text-danger, var(--text-secondary));">
                    −{diff.stats.deletions}
                  </span>
                  <span style="color: var(--text-muted);">
                    across {diff.stats.files} {if diff.stats.files == 1, do: "file", else: "files"}
                  </span>
                  <span :if={diff.sha} style="color: var(--text-muted);">
                    · <code>{String.slice(diff.sha, 0, 7)}</code>
                  </span>
                </div>
                <details :if={diff.files != []} class="mt-2">
                  <summary class="cursor-pointer" style="color: var(--text-muted);">
                    files
                  </summary>
                  <ul role="list" class="mt-1 pl-2">
                    <li
                      :for={f <- diff.files}
                      style="color: var(--text-secondary);"
                    >
                      <span style="color: var(--text-brand);">+{f.additions}</span>
                      <span style="color: var(--text-danger, var(--text-secondary));">
                        −{f.deletions}
                      </span>
                      <span class="ml-2">{f.path}</span>
                    </li>
                  </ul>
                </details>
                <details :if={diff.patch_excerpt != ""} class="mt-2">
                  <summary class="cursor-pointer" style="color: var(--text-muted);">
                    patch excerpt
                  </summary>
                  <pre
                    class="mt-1 whitespace-pre-wrap rounded p-2 text-xs"
                    style="background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border-subtle);"
                  >{diff.patch_excerpt}</pre>
                </details>
              </div>
              <details class="mt-3 text-xs font-mono">
                <summary
                  class="cursor-pointer"
                  style="color: var(--text-muted);"
                >
                  4-phase events
                </summary>
                <ol :if={Map.has_key?(@wu_events, wu.id)} class="mt-2 flex flex-col gap-1 pl-2">
                  <li
                    :for={ev <- Enum.reverse(Map.get(@wu_events, wu.id, []))}
                    style="color: var(--text-secondary);"
                  >
                    {inspect(ev)}
                  </li>
                </ol>
                <p
                  :if={!Map.has_key?(@wu_events, wu.id)}
                  class="mt-2 pl-2"
                  style="color: var(--text-muted);"
                >
                  no live events yet
                </p>
              </details>
            </li>
          </ul>
        </section>

        <section class="card p-6 mt-6" aria-labelledby="orch-shepherd-h">
          <h2
            id="orch-shepherd-h"
            class="text-sm font-medium mb-3 uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            pr shepherd
          </h2>

          <%= cond do %>
            <% is_nil(@pr_ref) -> %>
              <p class="text-sm" style="color: var(--text-muted);">
                No PR reference recorded for this epic.
                Populate <code>epic.metadata.pr_ref</code>
                with <code>["owner", "repo", number]</code>
                to enable shepherding.
              </p>
            <% is_nil(@shepherd_status) -> %>
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm" style="color: var(--text-muted);">
                  No shepherd active for <code>{elem(@pr_ref, 0)}/{elem(@pr_ref, 1)}#{elem(@pr_ref, 2)}</code>.
                </p>
                <button
                  type="button"
                  class="loom-btn-primary"
                  phx-click="spawn_shepherd"
                  aria-label="Spawn PR shepherd"
                >
                  spawn shepherd
                </button>
              </div>
            <% true -> %>
              <% {scls, slbl} = shepherd_badge(@shepherd_status.state) %>
              <div class="flex items-center gap-3 text-sm">
                <span class={scls}>{slbl}</span>
                <span style="color: var(--text-secondary);">
                  ci:
                  <strong style="color: var(--text-primary);">
                    {to_string(@shepherd_status.ci || "—")}
                  </strong>
                </span>
                <span style="color: var(--text-secondary);">
                  comments:
                  <strong style="color: var(--text-primary);">
                    {@shepherd_status.unresolved_count}/{@shepherd_status.comment_count}
                  </strong>
                </span>
                <span style="color: var(--text-secondary);">
                  polls: <strong style="color: var(--text-primary);">{@shepherd_status.polls}</strong>
                </span>
              </div>
              <p
                :if={@shepherd_status.reason}
                class="mt-2 text-xs font-mono"
                style="color: var(--text-muted);"
              >
                reason: {inspect(@shepherd_status.reason)}
              </p>
          <% end %>
        </section>
      </div>
    </main>
    """
  end
end
