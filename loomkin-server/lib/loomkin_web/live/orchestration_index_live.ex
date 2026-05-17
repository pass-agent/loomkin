defmodule LoomkinWeb.OrchestrationIndexLive do
  @moduledoc """
  Lists in-flight and recent orchestration epics with their current phase.

  Subscribes to `orchestration.epic` so phase badges update without a refresh.
  Styling reuses the project's Cozy Studio tokens (see `assets/css/app.css`)
  and the existing `.card`, `.badge`, `.loom-btn-*` utility classes.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Orchestration
  alias Loomkin.Orchestration.{Context, SwarmCoordinator}

  @topic "orchestration.epic"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Loomkin.PubSub, @topic)

    {:ok,
     socket
     |> assign(:page_title, "Orchestration")
     |> assign(:phase_list, Orchestration.phases())
     |> assign(:create_error, nil)
     |> load_epics()}
  end

  defp load_epics(socket) do
    assign(socket, :epics, Context.list_epics(limit: 50))
  end

  @impl true
  def handle_info({@topic, %{}}, socket) do
    {:noreply, load_epics(socket)}
  end

  def handle_info({@topic, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_epic", %{"epic" => params}, socket) do
    case Context.create_epic(%{
           title: params["title"],
           spec: params["spec"] || "",
           priority: 2
         }) do
      {:ok, epic} ->
        epic_map = %{id: epic.id, title: epic.title, spec: epic.spec}
        callbacks = Loomkin.Orchestration.Callbacks.default_issue_callbacks()
        {:ok, _pid} = SwarmCoordinator.submit(epic_map, callbacks: callbacks)

        {:noreply,
         socket
         |> put_flash(:info, "Orchestrating epic #{epic.title}")
         |> assign(:create_error, nil)
         |> load_epics()}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_error, summarize_errors(changeset))}
    end
  end

  defp summarize_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map_join("; ", fn {k, {msg, _}} -> "#{k} #{msg}" end)
  end

  defp phase_index(nil, _list), do: -1

  defp phase_index(phase, list) when is_atom(phase),
    do: Enum.find_index(list, &(&1 == phase)) || -1

  defp phase_index(phase, list) when is_binary(phase),
    do: Enum.find_index(list, &(Atom.to_string(&1) == phase)) || -1

  defp phase_label(nil), do: "—"
  defp phase_label(p) when is_atom(p), do: Atom.to_string(p)
  defp phase_label(p) when is_binary(p), do: p

  defp status_badge(:closed), do: {"badge badge-success", "closed"}
  defp status_badge(:failed), do: {"badge badge-danger", "failed"}
  defp status_badge(:awaiting_human), do: {"badge badge-warning", "awaiting human"}
  defp status_badge(:in_progress), do: {"badge", "in progress"}
  defp status_badge(:pending), do: {"badge", "pending"}
  defp status_badge(other), do: {"badge", to_string(other)}

  @impl true
  def render(assigns) do
    ~H"""
    <main
      class="min-h-screen px-6 py-10"
      style="background: var(--surface-0); color: var(--text-primary);"
      aria-labelledby="orch-index-h"
    >
      <header class="max-w-5xl mx-auto mb-8">
        <p class="text-xs font-mono mb-2" style="color: var(--text-muted);">
          <.link navigate={~p"/"} class="hover:underline">← home</.link>
          <span class="mx-1">·</span>
          <.link navigate={~p"/orchestration/knowledge"} class="hover:underline">knowledge</.link>
          <span class="mx-1">·</span>
          <.link navigate={~p"/orchestration/metrics"} class="hover:underline">metrics</.link>
        </p>
        <h1 id="orch-index-h" class="text-2xl font-semibold" style="color: var(--text-primary);">
          Orchestration epics
        </h1>
        <p class="text-sm mt-1" style="color: var(--text-secondary);">
          9-phase pipeline · adversarial review gates · live phase progression
        </p>
      </header>

      <section
        class="card max-w-5xl mx-auto mb-8 p-6"
        aria-labelledby="orch-new-h"
      >
        <h2 id="orch-new-h" class="text-lg font-medium mb-4" style="color: var(--text-primary);">
          Start a new epic
        </h2>
        <form phx-submit="create_epic" class="flex flex-col gap-4">
          <label class="flex flex-col gap-1 text-sm" style="color: var(--text-secondary);">
            <span>Title</span>
            <input
              name="epic[title]"
              type="text"
              required
              maxlength="120"
              class="rounded px-3 py-2 text-sm focus:outline-none focus:ring-2"
              style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
            />
          </label>
          <label class="flex flex-col gap-1 text-sm" style="color: var(--text-secondary);">
            <span>Spec</span>
            <textarea
              name="epic[spec]"
              rows="4"
              required
              class="rounded px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2"
              style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
            ></textarea>
          </label>
          <button type="submit" class="loom-btn loom-btn-solid self-start">
            Orchestrate
          </button>
        </form>
        <p :if={@create_error} role="alert" class="mt-3 text-sm" style="color: var(--accent-rose);">
          {@create_error}
        </p>
      </section>

      <section class="max-w-5xl mx-auto" aria-labelledby="orch-list-h">
        <h2 id="orch-list-h" class="text-lg font-medium mb-4" style="color: var(--text-primary);">
          Recent epics
        </h2>

        <p
          :if={@epics == []}
          class="card p-6 text-sm"
          style="color: var(--text-muted);"
        >
          No epics yet — start one above.
        </p>

        <ul :if={@epics != []} role="list" class="flex flex-col gap-3">
          <li :for={epic <- @epics} class="card hover-lift p-4">
            <.link
              navigate={~p"/orchestration/#{epic.id}"}
              class="flex items-baseline justify-between gap-3 no-underline"
              style="color: inherit;"
            >
              <strong class="font-medium" style="color: var(--text-primary);">
                {epic.title}
              </strong>
              <% {cls, lbl} = status_badge(epic.status) %>
              <span class={cls}>{lbl}</span>
            </.link>

            <div
              class="mt-3 flex items-center gap-2"
              role="img"
              aria-label={"phase " <> phase_label(epic.current_phase)}
            >
              <span
                :for={{ph, i} <- Enum.with_index(@phase_list)}
                title={Atom.to_string(ph)}
                class="block h-2 w-2 rounded-full"
                style={
                  if i <= phase_index(epic.current_phase, @phase_list) do
                    "background: var(--brand);"
                  else
                    "background: var(--surface-3);"
                  end
                }
              >
              </span>
              <span class="ml-2 text-xs font-mono" style="color: var(--text-muted);">
                phase: {phase_label(epic.current_phase)}
              </span>
            </div>
          </li>
        </ul>
      </section>
    </main>
    """
  end
end
