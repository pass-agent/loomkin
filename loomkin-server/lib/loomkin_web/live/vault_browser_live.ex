defmodule LoomkinWeb.VaultBrowserLive do
  @moduledoc "Vault knowledge base browser — browse, search, and filter vault entries."

  use LoomkinWeb, :live_view

  alias Loomkin.Vault
  alias Loomkin.Vault.Index

  @type_icons %{
    "note" =>
      "M19 20H5a2 2 0 01-2-2V6a2 2 0 012-2h10a2 2 0 012 2v1m2 13a2 2 0 01-2-2V7m2 13a2 2 0 002-2V9a2 2 0 00-2-2h-2",
    "topic" =>
      "M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A2 2 0 013 12V7a4 4 0 014-4z",
    "project" => "M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z",
    "person" => "M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z",
    "decision" =>
      "M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z",
    "meeting" =>
      "M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z",
    "checkin" =>
      "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4",
    "idea" =>
      "M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z",
    "source" =>
      "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1",
    "okr" => "M13 10V3L4 14h7v7l9-11h-7z"
  }

  @type_colors %{
    "note" => "text-accent-cyan",
    "topic" => "text-accent-mauve",
    "project" => "text-accent-amber",
    "person" => "text-accent-emerald",
    "decision" => "text-accent-rose",
    "meeting" => "text-accent-peach",
    "checkin" => "text-accent-emerald",
    "idea" => "text-accent-amber",
    "source" => "text-accent-cyan",
    "okr" => "text-accent-rose"
  }

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    vault = Vault.get_vault_by_slug!(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if Vault.user_can_access_vault?(user, vault) do
      type_counts = Vault.stats(slug).by_type
      entries = Index.list(slug, limit: 50, order_by: {:desc, :updated_at})

      {:ok,
       socket
       |> assign(
         vault: vault,
         slug: slug,
         type_counts: type_counts,
         active_type: nil,
         search_query: "",
         page_title: vault.name
       )
       |> stream(:entries, entries)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to this vault.")
       |> redirect(to: "/")}
    end
  end

  @impl true
  def handle_event("search", %{"query" => ""}, socket) do
    entries = Index.list(socket.assigns.slug, limit: 50, order_by: {:desc, :updated_at})

    {:noreply,
     socket
     |> assign(search_query: "", active_type: nil)
     |> stream(:entries, entries, reset: true)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results = Vault.search(socket.assigns.slug, query, limit: 50)

    {:noreply,
     socket
     |> assign(search_query: query, active_type: nil)
     |> stream(:entries, results, reset: true)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    active_type = if type == socket.assigns.active_type, do: nil, else: type

    entries =
      if active_type do
        Index.list(socket.assigns.slug, entry_type: active_type, limit: 100)
      else
        Index.list(socket.assigns.slug, limit: 50, order_by: {:desc, :updated_at})
      end

    {:noreply,
     socket
     |> assign(active_type: active_type, search_query: "")
     |> stream(:entries, entries, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col" style="background: var(--surface-0);">
      <%!-- Top bar --%>
      <header
        class="sticky top-0 z-30 flex items-center gap-4 px-6 py-4 border-b"
        style="background: var(--surface-1); border-color: var(--border-default);"
      >
        <div class="flex items-center gap-3">
          <div
            class="w-8 h-8 rounded-lg flex items-center justify-center"
            style="background: var(--brand-subtle);"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-4 h-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="1.5"
              style="color: var(--brand);"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253"
              />
            </svg>
          </div>
          <h1 class="text-lg font-semibold" style="color: var(--text-primary);">
            {@vault.name}
          </h1>
        </div>

        <div class="flex-1 max-w-xl ml-8">
          <form phx-change="search" phx-submit="search" class="relative">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="1.5"
              style="color: var(--text-muted);"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search entries..."
              phx-debounce="300"
              autocomplete="off"
              class="w-full pl-10 pr-4 py-2 rounded-lg text-sm border-0 outline-none focus:ring-1"
              style="background: var(--surface-2); color: var(--text-primary); --tw-ring-color: var(--brand);"
            />
          </form>
        </div>

        <div class="ml-auto text-sm" style="color: var(--text-muted);">
          {total_count(@type_counts)} entries
        </div>
      </header>

      <div class="flex flex-1 overflow-hidden">
        <%!-- Sidebar: entry types --%>
        <nav
          class="w-56 shrink-0 overflow-y-auto py-4 px-3 border-r hidden md:block"
          style="background: var(--surface-1); border-color: var(--border-subtle);"
        >
          <p
            class="px-3 pb-2 text-xs font-medium uppercase tracking-wider"
            style="color: var(--text-muted);"
          >
            Types
          </p>
          <div class="space-y-0.5">
            <button
              :for={{type, count} <- sorted_types(@type_counts)}
              phx-click="filter_type"
              phx-value-type={type}
              class={[
                "w-full flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-all",
                "hover:bg-[var(--surface-2)]",
                @active_type == type && "bg-[var(--brand-subtle)]"
              ]}
              style={
                if @active_type == type,
                  do: "color: var(--text-brand);",
                  else: "color: var(--text-secondary);"
              }
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class={["w-4 h-4 shrink-0", type_color(type)]}
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d={type_icon(type)} />
              </svg>
              <span class="truncate">{type_label(type)}</span>
              <span
                class="ml-auto text-xs tabular-nums"
                style="color: var(--text-muted);"
              >
                {count}
              </span>
            </button>
          </div>
        </nav>

        <%!-- Main: entry list --%>
        <main class="flex-1 overflow-y-auto" style="background: var(--surface-0);">
          <div
            id="entries"
            phx-update="stream"
            class="divide-y"
            style="border-color: var(--border-subtle);"
          >
            <.entry_row
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              entry={entry}
              slug={@slug}
            />
          </div>

          <div class="hidden only:flex flex-col items-center justify-center py-24 px-6">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-12 h-12 mb-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="1"
              style="color: var(--text-muted);"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253"
              />
            </svg>
            <p class="text-sm" style="color: var(--text-muted);">
              <%= if @search_query != "" do %>
                No results for "<span style="color: var(--text-secondary);"><%= @search_query %></span>"
              <% else %>
                No entries yet
              <% end %>
            </p>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp entry_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/vault/#{@slug}/#{@entry.path}"}
      id={@id}
      class="flex items-start gap-4 px-6 py-4 transition-colors hover:bg-[var(--surface-1)] group"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class={["w-4 h-4 mt-0.5 shrink-0", type_color(@entry.entry_type)]}
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        stroke-width="1.5"
      >
        <path stroke-linecap="round" stroke-linejoin="round" d={type_icon(@entry.entry_type)} />
      </svg>

      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <h3
            class="text-sm font-medium truncate group-hover:text-[var(--brand)]"
            style="color: var(--text-primary); transition: color var(--transition-fast);"
          >
            {@entry.title || Path.basename(@entry.path, ".md")}
          </h3>
          <span
            :if={@entry.entry_type}
            class="shrink-0 text-[10px] font-medium uppercase tracking-wider px-1.5 py-0.5 rounded"
            style="background: var(--surface-2); color: var(--text-muted);"
          >
            {@entry.entry_type}
          </span>
        </div>
        <div class="flex items-center gap-3 mt-1">
          <span
            :if={@entry.updated_at}
            class="text-xs"
            style="color: var(--text-muted);"
          >
            {format_date(@entry.updated_at)}
          </span>
          <span
            :for={tag <- @entry.tags || []}
            class="text-xs px-1.5 py-0.5 rounded"
            style="background: var(--brand-muted); color: var(--text-brand);"
          >
            {tag}
          </span>
        </div>
      </div>

      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-4 h-4 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        stroke-width="1.5"
        style="color: var(--text-muted);"
      >
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
      </svg>
    </.link>
    """
  end

  # --- Helpers ---

  defp type_icon(type),
    do:
      Map.get(
        @type_icons,
        type,
        "M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
      )

  defp type_color(type), do: Map.get(@type_colors, type, "text-[var(--text-muted)]")

  defp type_label(nil), do: "Other"

  defp type_label(type) do
    type |> String.replace("_", " ") |> String.capitalize() |> Kernel.<>("s")
  end

  defp sorted_types(type_counts) do
    type_counts
    |> Enum.sort_by(fn {_type, count} -> -count end)
  end

  defp total_count(type_counts) do
    type_counts |> Map.values() |> Enum.sum()
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(_), do: ""
end
