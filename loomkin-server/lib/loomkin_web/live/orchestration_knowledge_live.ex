defmodule LoomkinWeb.OrchestrationKnowledgeLive do
  @moduledoc """
  Browse + filter `Loomkin.Orchestration.Schema.KnowledgeFact` rows.

  Surfaces every fact the orchestration framework has accumulated: ones the
  Curator extracted (default `confidence: :medium`), ones imported from a
  JSONL knowledge file, and ones a human added directly. Lets a logged-in
  user **promote** a `:medium` fact to `:high` after manual review.

  Subscribes to `orchestration.knowledge` so newly added facts appear without
  refresh.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Orchestration.{KnowledgeStore, Schema.KnowledgeFact}

  @topic "orchestration.knowledge"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Loomkin.PubSub, @topic)

    {:ok,
     socket
     |> assign(:page_title, "Knowledge")
     |> assign(:filters, %{type: nil, confidence: nil, tag: ""})
     |> assign(:types, KnowledgeFact.types())
     |> assign(:confidences, KnowledgeFact.confidences())
     |> load_facts()}
  end

  defp load_facts(socket) do
    filters = build_filters(socket.assigns.filters)
    assign(socket, :facts, KnowledgeStore.list_facts(filters))
  end

  defp build_filters(%{type: type, confidence: conf, tag: tag}) do
    %{}
    |> maybe_put(:type, type)
    |> maybe_put(:confidence, conf)
    |> maybe_put(:tag, blank_to_nil(tag))
    |> Map.put(:limit, 200)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(s) when is_binary(s) and s != "", do: s
  defp blank_to_nil(_), do: nil

  @impl true
  def handle_info({@topic, _msg}, socket), do: {:noreply, load_facts(socket)}

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      type: parse_atom_or_nil(params["type"], KnowledgeFact.types()),
      confidence: parse_atom_or_nil(params["confidence"], KnowledgeFact.confidences()),
      tag: params["tag"] || ""
    }

    {:noreply, socket |> assign(:filters, filters) |> load_facts()}
  end

  def handle_event("promote", %{"id" => id}, socket) do
    case KnowledgeStore.get_fact(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "fact not found")}

      fact ->
        attrs = %{id: fact.id, confidence: :high}
        _ = KnowledgeStore.put_fact(attrs)
        {:noreply, socket |> put_flash(:info, "promoted to high confidence") |> load_facts()}
    end
  end

  defp parse_atom_or_nil("", _allowed), do: nil
  defp parse_atom_or_nil(nil, _allowed), do: nil

  defp parse_atom_or_nil(s, allowed) when is_binary(s) do
    atom = String.to_atom(s)
    if atom in allowed, do: atom, else: nil
  end

  defp confidence_badge(:high), do: {"badge badge-success", "high"}
  defp confidence_badge(:medium), do: {"badge badge-warning", "medium"}
  defp confidence_badge(:low), do: {"badge", "low"}
  defp confidence_badge(other), do: {"badge", to_string(other)}

  @impl true
  def render(assigns) do
    ~H"""
    <main
      class="min-h-screen px-6 py-10"
      style="background: var(--surface-0); color: var(--text-primary);"
      aria-labelledby="kn-h"
    >
      <div class="max-w-5xl mx-auto">
        <header class="mb-8">
          <p class="text-xs font-mono mb-2" style="color: var(--text-muted);">
            <.link navigate={~p"/orchestration"} class="hover:underline">← orchestration</.link>
          </p>
          <h1 id="kn-h" class="text-2xl font-semibold">Knowledge base</h1>
          <p class="text-sm mt-1" style="color: var(--text-secondary);">
            Facts the orchestration framework has learned. Curator-extracted facts start at <code>medium</code>; promote after manual review.
          </p>
        </header>

        <section class="card p-4 mb-6" aria-labelledby="kn-filter-h">
          <h2 id="kn-filter-h" class="sr-only">Filters</h2>
          <form phx-change="filter" class="flex flex-wrap items-end gap-4">
            <label class="flex flex-col gap-1 text-xs font-mono" style="color: var(--text-muted);">
              type
              <select
                name="filters[type]"
                class="rounded px-2 py-1.5 text-sm"
                style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
              >
                <option value="" selected={@filters.type == nil}>all</option>
                <option
                  :for={t <- @types}
                  value={Atom.to_string(t)}
                  selected={@filters.type == t}
                >
                  {t}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1 text-xs font-mono" style="color: var(--text-muted);">
              confidence
              <select
                name="filters[confidence]"
                class="rounded px-2 py-1.5 text-sm"
                style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
              >
                <option value="" selected={@filters.confidence == nil}>all</option>
                <option
                  :for={c <- @confidences}
                  value={Atom.to_string(c)}
                  selected={@filters.confidence == c}
                >
                  {c}
                </option>
              </select>
            </label>

            <label
              class="flex flex-col gap-1 text-xs font-mono flex-1 min-w-[180px]"
              style="color: var(--text-muted);"
            >
              tag contains
              <input
                name="filters[tag]"
                type="text"
                value={@filters.tag}
                class="rounded px-2 py-1.5 text-sm"
                style="background: var(--surface-1); border: 1px solid var(--border-default); color: var(--text-primary);"
              />
            </label>
          </form>
        </section>

        <section aria-labelledby="kn-list-h">
          <h2 id="kn-list-h" class="sr-only">Facts</h2>
          <p
            :if={@facts == []}
            class="card p-6 text-sm"
            style="color: var(--text-muted);"
          >
            No facts match the current filters.
          </p>
          <ul :if={@facts != []} role="list" class="flex flex-col gap-3">
            <li :for={fact <- @facts} class="card p-4">
              <div class="flex items-baseline justify-between gap-3">
                <span class="font-medium" style="color: var(--text-primary);">{fact.fact}</span>
                <% {ccls, clbl} = confidence_badge(fact.confidence) %>
                <span class={ccls}>{clbl}</span>
              </div>
              <p
                :if={fact.recommendation && fact.recommendation != ""}
                class="text-sm mt-2"
                style="color: var(--text-secondary);"
              >
                {fact.recommendation}
              </p>
              <div
                class="mt-3 flex flex-wrap items-center gap-2 text-xs font-mono"
                style="color: var(--text-muted);"
              >
                <span
                  class="rounded px-1.5 py-0.5"
                  style="background: var(--brand-subtle); color: var(--text-brand);"
                >
                  {fact.type}
                </span>
                <span
                  :for={tag <- fact.tags || []}
                  class="rounded px-1.5 py-0.5"
                  style="background: var(--surface-2); color: var(--text-secondary);"
                >
                  {tag}
                </span>
                <button
                  :if={fact.confidence == :medium}
                  type="button"
                  phx-click="promote"
                  phx-value-id={fact.id}
                  class="ml-auto loom-btn loom-btn-ghost text-[10px] uppercase tracking-wider"
                >
                  promote to high
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </main>
    """
  end
end
