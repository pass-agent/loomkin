defmodule LoomkinWeb.OrchestrationPanelComponent do
  @moduledoc """
  Sticky "current activity" panel rendered at the top of
  `OrchestrationShowLive`. Mirrors the CLI's `OrchestrationEpicCard` —
  one card per epic with the current persona, 9-dot progress, work-unit
  count, status, last event, and action hints.

  Action buttons are intentionally dead links for this milestone
  (r14 will wire pause/cancel/open).

  Subscribes to `orchestration.epic` and `orchestration.work_unit`
  PubSub topics on mount so updates flow without a parent refresh.
  Styling uses Cozy Studio tokens (`card`, `loom-btn-ghost`, etc.).
  """
  use LoomkinWeb, :live_component

  alias Loomkin.Orchestration
  alias Loomkin.Orchestration.Context
  alias Loomkin.Orchestration.Metrics
  alias Loomkin.Orchestration.Personas
  alias Loomkin.Orchestration.SwarmCoordinator

  @epic_topic "orchestration.epic"
  @wu_topic "orchestration.work_unit"

  @impl true
  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @epic_topic)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @wu_topic)
    end

    {:ok,
     socket
     |> assign(:persona, default_persona())
     |> assign(:work_unit_count, 0)
     |> assign(:last_event, nil)
     |> assign(:status, :monitoring)
     |> assign(:phase_list, Orchestration.phases())}
  end

  @impl true
  def update(%{epic: epic} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:work_unit_count, work_unit_count_for(epic))
     |> assign(:status, status_for(epic))
     |> assign(:persona, persona_for_epic(epic))
     |> assign(:cost_usd, cost_for(epic))
     |> assign(:eta_ms, eta_for(epic))}
  end

  defp cost_for(%{id: id}) when is_binary(id) do
    Metrics.cost_for_epic(id)
  rescue
    _ -> nil
  end

  defp cost_for(_), do: nil

  defp eta_for(%{id: id, current_phase: phase}) when is_binary(id) do
    Metrics.eta_for_epic(id, phase)
  rescue
    _ -> nil
  end

  defp eta_for(_), do: nil

  @doc "Public formatting helpers shared with `OrchestrationShowLive`."
  def format_cost(nil), do: "—"

  def format_cost(%Decimal{} = d) do
    # Render with 2 fractional digits, e.g. "$0.43" / "$12.00".
    rounded = Decimal.round(d, 2)
    "$" <> Decimal.to_string(rounded, :normal)
  end

  def format_cost(_), do: "—"

  def format_eta(nil), do: "—"

  def format_eta(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    cond do
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  def format_eta(_), do: "—"

  @impl true
  def handle_event("pause", %{"id" => epic_id}, socket) do
    SwarmCoordinator.pause(epic_id)
    {:noreply, socket}
  end

  def handle_event("cancel", %{"id" => epic_id}, socket) do
    SwarmCoordinator.cancel(epic_id)
    {:noreply, socket}
  end

  def handle_event("resume", %{"id" => epic_id}, socket) do
    SwarmCoordinator.resume(epic_id)
    {:noreply, socket}
  end

  def handle_event("approve", %{"id" => epic_id}, socket) do
    SwarmCoordinator.approve(epic_id)
    {:noreply, socket}
  end

  def handle_event("reject", %{"id" => epic_id}, socket) do
    SwarmCoordinator.reject(epic_id)
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp work_unit_count_for(%{id: id}) do
    Context.list_work_units(id) |> length()
  rescue
    _ -> 0
  end

  defp work_unit_count_for(_), do: 0

  defp status_for(%{status: status} = epic) when is_atom(status) do
    cond do
      status == :closed -> :closed
      status == :failed -> :failed
      status == :cancelled -> :cancelled
      status == :awaiting_human and awaiting_approval?(epic) -> :awaiting_approval
      status == :awaiting_human -> :escalated
      paused?(epic) -> :paused
      true -> :monitoring
    end
  end

  defp status_for(_), do: :monitoring

  defp paused?(%{metadata: %{} = meta}) do
    Map.get(meta, "paused") == true or Map.get(meta, :paused) == true
  end

  defp paused?(_), do: false

  defp awaiting_approval?(%{metadata: %{} = meta}) do
    Map.get(meta, "awaiting_approval") == true or
      Map.get(meta, :awaiting_approval) == true or
      not is_nil(Map.get(meta, "approval_reason")) or
      not is_nil(Map.get(meta, :approval_reason))
  end

  defp awaiting_approval?(_), do: false

  defp persona_for_epic(%{current_phase: phase}) when is_binary(phase) do
    Personas.for_phase(safe_atom(phase))
  end

  defp persona_for_epic(_), do: default_persona()

  defp default_persona, do: Personas.for_phase(:pending)

  defp safe_atom(phase) when is_binary(phase) do
    String.to_existing_atom(phase)
  rescue
    _ -> :pending
  end

  defp phase_index(nil, _), do: -1

  defp phase_index(phase, list) when is_atom(phase),
    do: Enum.find_index(list, &(&1 == phase)) || -1

  defp phase_index(phase, list) when is_binary(phase),
    do: Enum.find_index(list, &(Atom.to_string(&1) == phase)) || -1

  defp status_badge(:closed), do: {"badge badge-success", "closed"}
  defp status_badge(:failed), do: {"badge badge-danger", "failed"}
  defp status_badge(:escalated), do: {"badge badge-warning", "escalated"}
  defp status_badge(:paused), do: {"badge badge-warning", "paused"}
  defp status_badge(:cancelled), do: {"badge", "cancelled"}
  defp status_badge(:awaiting_approval), do: {"badge badge-warning", "awaiting approval"}
  defp status_badge(_), do: {"badge", "monitoring"}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      class="card p-6 mb-6"
      aria-labelledby={"orch-panel-h-" <> @epic.id}
      data-testid="orchestration-epic-card"
    >
      <header class="flex items-center justify-between gap-3 mb-3">
        <h2
          id={"orch-panel-h-" <> @epic.id}
          class="text-sm font-medium uppercase tracking-wider flex items-center gap-2"
          style="color: var(--text-muted);"
        >
          <span aria-hidden="true">{@persona.icon}</span>
          <span style="color: var(--text-primary);">{@persona.name}</span>
          <span style="color: var(--text-muted);">
            · {@persona.role_blurb}
          </span>
        </h2>
        <% {scls, slbl} = status_badge(@status) %>
        <span class={scls}>{slbl}</span>
      </header>

      <p class="text-sm mb-3" style="color: var(--text-secondary);">
        Epic: <strong style="color: var(--text-primary);">{@epic.title}</strong>
      </p>

      <p class="text-xs font-mono mb-3" style="color: var(--text-muted);">
        Phase: <strong style="color: var(--text-primary);">{@epic.current_phase || "—"}</strong>
      </p>

      <ol class="flex gap-1.5 mb-4" role="list" aria-label="Phase progress">
        <li
          :for={{_ph, i} <- Enum.with_index(@phase_list)}
          class="block h-2.5 w-2.5 rounded-full"
          style={
            if i <= phase_index(@epic.current_phase, @phase_list) do
              "background: var(--brand);"
            else
              "background: var(--surface-3);"
            end
          }
          aria-hidden="true"
        >
        </li>
      </ol>

      <dl class="text-xs grid grid-cols-2 gap-x-6 gap-y-1 mb-3 font-mono">
        <dt style="color: var(--text-muted);">Work units</dt>
        <dd style="color: var(--text-primary);">{@work_unit_count}</dd>
        <dt style="color: var(--text-muted);">Last event</dt>
        <dd style="color: var(--text-primary);">{@last_event || "—"}</dd>
        <dt style="color: var(--text-muted);">Cost</dt>
        <dd
          style="color: var(--text-primary);"
          data-testid="orchestration-card-cost"
        >
          {format_cost(@cost_usd)}
        </dd>
        <dt style="color: var(--text-muted);">ETA</dt>
        <dd
          style="color: var(--text-primary);"
          data-testid="orchestration-card-eta"
        >
          {format_eta(@eta_ms)}
        </dd>
      </dl>

      <div
        :if={@status == :awaiting_approval}
        class="mb-3 rounded p-3"
        style="background: var(--surface-1); border: 1px solid var(--border-default);"
      >
        <p class="text-sm mb-2" style="color: var(--text-primary);">
          <strong>Approval requested</strong> — review the pending change before continuing.
        </p>
        <div class="flex gap-2">
          <button
            type="button"
            class="loom-btn loom-btn-solid"
            phx-click="approve"
            phx-target={@myself}
            phx-value-id={@epic.id}
            aria-label="Approve and continue"
          >
            [a] approve
          </button>
          <button
            type="button"
            class="loom-btn loom-btn-ghost"
            phx-click="reject"
            phx-target={@myself}
            phx-value-id={@epic.id}
            aria-label="Reject and stop"
          >
            [x] reject
          </button>
        </div>
      </div>

      <div class="flex gap-2" data-testid="orchestration-actions">
        <button
          :if={@status in [:monitoring, :awaiting_approval]}
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="pause"
          phx-target={@myself}
          phx-value-id={@epic.id}
          aria-label="Pause epic"
        >
          [p] pause
        </button>
        <button
          :if={@status == :paused}
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="resume"
          phx-target={@myself}
          phx-value-id={@epic.id}
          aria-label="Resume epic"
        >
          [r] resume
        </button>
        <button
          :if={@status not in [:closed, :failed, :cancelled]}
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="cancel"
          phx-target={@myself}
          phx-value-id={@epic.id}
          aria-label="Cancel epic"
        >
          [c] cancel
        </button>
        <button
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="open"
          phx-target={@myself}
          aria-label="Open dashboard (coming soon)"
          disabled
        >
          [o] open dashboard
        </button>
      </div>
    </section>
    """
  end
end
