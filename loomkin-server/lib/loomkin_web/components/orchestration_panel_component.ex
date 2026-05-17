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
  alias Loomkin.Orchestration.Personas

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
     |> assign(:persona, persona_for_epic(epic))}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    # All buttons are dead-links until r14 wires real intents.
    {:noreply, socket}
  end

  defp work_unit_count_for(%{id: id}) do
    Context.list_work_units(id) |> length()
  rescue
    _ -> 0
  end

  defp work_unit_count_for(_), do: 0

  defp status_for(%{status: status}) when is_atom(status) do
    case status do
      :closed -> :closed
      :failed -> :failed
      :awaiting_human -> :escalated
      _ -> :monitoring
    end
  end

  defp status_for(_), do: :monitoring

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
      </dl>

      <div class="flex gap-2">
        <button
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="pause"
          phx-target={@myself}
          aria-label="Pause epic (coming soon)"
          disabled
        >
          [p] pause
        </button>
        <button
          type="button"
          class="loom-btn loom-btn-ghost"
          phx-click="cancel"
          phx-target={@myself}
          aria-label="Cancel epic (coming soon)"
          disabled
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
