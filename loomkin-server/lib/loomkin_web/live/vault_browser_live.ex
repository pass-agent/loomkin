defmodule LoomkinWeb.VaultBrowserLive do
  @moduledoc "Vault knowledge base browser — browse, search, and filter vault entries."

  use LoomkinWeb, :live_view

  alias Loomkin.Vault
  alias Loomkin.Vault.Index

  @type_colors %{
    "note" => "--accent-cyan",
    "topic" => "--accent-mauve",
    "project" => "--accent-amber",
    "person" => "--accent-emerald",
    "decision" => "--accent-rose",
    "meeting" => "--accent-peach",
    "checkin" => "--accent-emerald",
    "idea" => "--accent-amber",
    "source" => "--accent-cyan",
    "spec" => "--accent-mauve",
    "milestone" => "--accent-peach",
    "okr" => "--accent-rose"
  }

  @page_size 30

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    vault = Vault.get_vault_by_slug!(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if Vault.user_can_access_vault?(user, vault) do
      type_counts = Vault.stats(slug).by_type
      total = total_count(type_counts)
      recent = Index.list(slug, limit: 5, order_by: {:desc, :updated_at})
      entries = Index.list(slug, limit: @page_size, order_by: {:desc, :updated_at})

      {:ok,
       socket
       |> assign(
         vault: vault,
         slug: slug,
         type_counts: type_counts,
         total: total,
         active_type: nil,
         search_query: "",
         recent: recent,
         page: 0,
         has_more: length(entries) >= @page_size,
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
    entries = Index.list(socket.assigns.slug, limit: @page_size, order_by: {:desc, :updated_at})

    {:noreply,
     socket
     |> assign(
       search_query: "",
       active_type: nil,
       page: 0,
       has_more: length(entries) >= @page_size
     )
     |> stream(:entries, entries, reset: true)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results = Vault.search(socket.assigns.slug, query, limit: @page_size)

    {:noreply,
     socket
     |> assign(
       search_query: query,
       active_type: nil,
       page: 0,
       has_more: length(results) >= @page_size
     )
     |> stream(:entries, results, reset: true)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    active_type = if type == socket.assigns.active_type, do: nil, else: type

    entries =
      if active_type do
        Index.list(socket.assigns.slug,
          entry_type: active_type,
          limit: @page_size,
          order_by: {:desc, :updated_at}
        )
      else
        Index.list(socket.assigns.slug, limit: @page_size, order_by: {:desc, :updated_at})
      end

    {:noreply,
     socket
     |> assign(
       active_type: active_type,
       search_query: "",
       page: 0,
       has_more: length(entries) >= @page_size
     )
     |> stream(:entries, entries, reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    offset = next_page * @page_size
    slug = socket.assigns.slug

    entries =
      cond do
        socket.assigns.search_query != "" ->
          Vault.search(slug, socket.assigns.search_query, limit: @page_size, offset: offset)

        socket.assigns.active_type ->
          Index.list(slug,
            entry_type: socket.assigns.active_type,
            limit: @page_size,
            offset: offset,
            order_by: {:desc, :updated_at}
          )

        true ->
          Index.list(slug, limit: @page_size, offset: offset, order_by: {:desc, :updated_at})
      end

    {:noreply,
     socket
     |> assign(page: next_page, has_more: length(entries) >= @page_size)
     |> stream(:entries, entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="vault-browser min-h-screen flex flex-col" style="background: var(--surface-0);">
      <%!-- Header — vault identity + search --%>
      <header class="vault-header sticky top-0 z-30 px-6 py-4" style="background: var(--surface-0);">
        <div class="max-w-7xl mx-auto flex items-center gap-6">
          <%!-- Vault identity --%>
          <div class="flex items-center gap-3">
            <.link navigate="/" class="vault-owl-mark" title="Home">
              <svg width="28" height="28" viewBox="0 0 32 32" fill="none">
                <%!-- Body --%>
                <path
                  d="M16 5C10.5 5 7 9 7 14c0 3 1.5 6 3.5 8C12.5 24 14 25.5 16 25.5s3.5-1.5 5.5-3.5c2-2 3.5-5 3.5-8 0-5-3.5-9-9-9z"
                  fill="var(--surface-1)"
                  stroke="var(--brand)"
                  stroke-width="0.8"
                />
                <%!-- Ear tufts --%>
                <path
                  d="M11 7.5L9.5 4M21 7.5l1.5-3.5"
                  stroke="var(--brand)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                />
                <%!-- Left eye --%>
                <circle
                  cx="13"
                  cy="14"
                  r="3"
                  fill="var(--surface-0)"
                  stroke="var(--accent-amber)"
                  stroke-width="0.6"
                />
                <circle cx="13.2" cy="13.7" r="1.3" fill="var(--accent-amber)" />
                <circle cx="12.6" cy="13.2" r="0.4" fill="var(--surface-0)" opacity="0.7" />
                <%!-- Right eye --%>
                <circle
                  cx="19"
                  cy="14"
                  r="3"
                  fill="var(--surface-0)"
                  stroke="var(--accent-amber)"
                  stroke-width="0.6"
                />
                <circle cx="19.2" cy="13.7" r="1.3" fill="var(--accent-amber)" />
                <circle cx="18.6" cy="13.2" r="0.4" fill="var(--surface-0)" opacity="0.7" />
                <%!-- Beak --%>
                <path
                  d="M15 18l1 1.5 1-1.5"
                  stroke="var(--accent-peach)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </.link>
            <div>
              <h1 class="text-base font-semibold" style="color: var(--text-primary);">
                {@vault.name}
              </h1>
              <p class="text-[10px] font-mono tracking-wider" style="color: var(--text-muted);">
                {total_count(@type_counts)} entries
              </p>
            </div>
          </div>

          <%!-- Search --%>
          <div class="flex-1 max-w-lg">
            <form phx-change="search" phx-submit="search" class="relative">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none"
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
                placeholder="Search the knowledge base..."
                phx-debounce="300"
                autocomplete="off"
                class="vault-search-input"
              />
            </form>
          </div>
        </div>
        <%!-- Subtle divider thread --%>
        <div class="vault-header-thread" />
      </header>

      <div class="flex flex-1 overflow-hidden max-w-7xl mx-auto w-full">
        <%!-- Sidebar: entry type facets --%>
        <nav class="vault-sidebar">
          <p
            class="px-3 pb-3 text-[10px] font-mono uppercase tracking-[0.15em]"
            style="color: var(--text-muted);"
          >
            Facets
          </p>
          <div class="space-y-0.5">
            <button
              :for={{type, count} <- sorted_types(@type_counts)}
              phx-click="filter_type"
              phx-value-type={type}
              class={[
                "vault-type-btn",
                @active_type == type && "active"
              ]}
            >
              <span
                class="vault-type-dot"
                style={"background: var(#{type_color_var(type)});"}
              />
              <span class="truncate flex-1 text-left">{type_label(type)}</span>
              <span class="vault-type-count">{count}</span>
            </button>
          </div>
        </nav>

        <%!-- Main content --%>
        <main class="flex-1 overflow-y-auto px-6 pb-12">
          <%!-- Recently updated — horizontal cards --%>
          <div
            :if={@search_query == "" and @active_type == nil and @recent != []}
            class="pt-6 pb-4"
          >
            <div class="flex items-center gap-2 mb-4">
              <div class="w-5 h-px" style="background: var(--brand); opacity: 0.4;" />
              <p
                class="text-[10px] font-mono uppercase tracking-[0.15em]"
                style="color: var(--text-muted);"
              >
                Recently woven
              </p>
              <div class="flex-1 h-px" style="background: var(--border-subtle);" />
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
              <.link
                :for={{entry, idx} <- Enum.with_index(@recent)}
                navigate={~p"/vault/#{@slug}/#{entry.path}"}
                class="vault-recent-card group"
                style={"animation: fadeUp 0.4s #{idx * 0.06}s cubic-bezier(0.16, 1, 0.3, 1) both;"}
              >
                <div
                  class="vault-card-thread"
                  style={"background: var(#{type_color_var(entry.entry_type)});"}
                />
                <div class="p-3.5">
                  <div class="flex items-center gap-2 mb-2.5">
                    <span
                      class="vault-type-dot"
                      style={"background: var(#{type_color_var(entry.entry_type)});"}
                    />
                    <span
                      class="text-[9px] font-mono uppercase tracking-widest"
                      style="color: var(--text-muted);"
                    >
                      {entry.entry_type}
                    </span>
                  </div>
                  <h3 class="vault-card-title">
                    {entry.title || Path.basename(entry.path, ".md")}
                  </h3>
                  <p
                    :if={body_preview(entry) != ""}
                    class="text-[11px] mt-1.5 line-clamp-2 leading-relaxed"
                    style="color: var(--text-muted);"
                  >
                    {body_preview(entry)}
                  </p>
                  <span
                    class="text-[10px] font-mono mt-3 block"
                    style="color: var(--text-muted); opacity: 0.7;"
                  >
                    {format_date(entry.updated_at)}
                  </span>
                </div>
              </.link>
            </div>
          </div>

          <%!-- Entry list heading --%>
          <div class="mb-3 mt-4">
            <div class="flex items-center gap-2">
              <div class="w-5 h-px" style="background: var(--brand); opacity: 0.4;" />
              <p
                class="text-[10px] font-mono uppercase tracking-[0.15em]"
                style="color: var(--text-muted);"
              >
                <%= cond do %>
                  <% @search_query != "" -> %>
                    Results for "{@search_query}"
                  <% @active_type -> %>
                    {type_label(@active_type)}
                  <% true -> %>
                    All entries
                <% end %>
              </p>
              <button
                :if={@active_type}
                phx-click="filter_type"
                phx-value-type={@active_type}
                class="text-[10px] font-mono px-1.5 py-0.5 rounded transition-colors hover:bg-[var(--surface-2)]"
                style="color: var(--text-muted);"
              >
                clear
              </button>
              <div class="flex-1 h-px" style="background: var(--border-subtle);" />
            </div>
          </div>

          <div id="entries" phx-update="stream" class="vault-entry-list">
            <.entry_row
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              entry={entry}
              slug={@slug}
            />
          </div>

          <%!-- Load more --%>
          <div :if={@has_more} class="flex justify-center py-6">
            <button
              phx-click="load_more"
              class="loom-btn loom-btn-ghost text-xs"
            >
              load more
            </button>
          </div>

          <%!-- Empty state --%>
          <div class="hidden only:flex flex-col items-center justify-center py-24 px-6">
            <div class="vault-empty-owl mb-6">
              <svg width="48" height="48" viewBox="0 0 32 32" fill="none">
                <path
                  d="M16 6C11 6 8 10 8 15c0 3 1 6 3 8 1.5 1.5 3 3 5 3s3.5-1.5 5-3c2-2 3-5 3-8 0-5-3-9-8-9z"
                  fill="var(--surface-2)"
                  stroke="var(--brand)"
                  stroke-width="0.8"
                />
                <path
                  d="M11 14.5c1-0.5 2-0.5 3 0"
                  stroke="var(--accent-amber)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                />
                <path
                  d="M18 14.5c1-0.5 2-0.5 3 0"
                  stroke="var(--accent-amber)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                />
                <path
                  d="M15 17l1 1 1-1"
                  stroke="var(--accent-peach)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </div>
            <p class="text-sm mb-1" style="color: var(--text-secondary);">
              <%= if @search_query != "" do %>
                No results for "<span style="color: var(--text-primary);"><%= @search_query %></span>"
              <% else %>
                The vault is quiet
              <% end %>
            </p>
            <p class="text-xs font-mono" style="color: var(--text-muted);">
              <%= if @search_query != "" do %>
                try a different query
              <% else %>
                entries appear here as agents weave knowledge
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
      class="vault-entry-row group"
    >
      <div
        class="vault-row-accent"
        style={"background: var(#{type_color_var(@entry.entry_type)});"}
      />
      <div class="flex items-start gap-3.5 flex-1 min-w-0 py-3.5 px-4">
        <span
          class="vault-type-dot mt-1.5 shrink-0"
          style={"background: var(#{type_color_var(@entry.entry_type)});"}
        />
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-2">
            <h3 class="vault-row-title">
              {@entry.title || Path.basename(@entry.path, ".md")}
            </h3>
            <span
              :if={@entry.entry_type}
              class="shrink-0 text-[9px] font-mono uppercase tracking-widest"
              style="color: var(--text-muted);"
            >
              {@entry.entry_type}
            </span>
          </div>
          <p
            :if={body_preview(@entry) != ""}
            class="text-[11px] mt-1 line-clamp-2 leading-relaxed"
            style="color: var(--text-muted);"
          >
            {body_preview(@entry)}
          </p>
          <div class="flex items-center gap-2.5 mt-2">
            <span
              :if={@entry.updated_at}
              class="text-[10px] font-mono"
              style="color: var(--text-muted); opacity: 0.7;"
            >
              {format_date(@entry.updated_at)}
            </span>
            <span
              :for={tag <- @entry.tags || []}
              class="vault-tag"
            >
              {tag}
            </span>
          </div>
        </div>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="w-4 h-4 shrink-0 mt-1.5 opacity-0 group-hover:opacity-60 transition-all group-hover:translate-x-0.5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="1.5"
          style="color: var(--brand);"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
        </svg>
      </div>
    </.link>
    """
  end

  # --- Helpers ---

  defp type_color_var(type), do: Map.get(@type_colors, type, "--text-muted")

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

  defp body_preview(%{body: nil}), do: ""
  defp body_preview(%{body: ""}), do: ""

  defp body_preview(%{body: body}) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(2)
    |> Enum.join(" ")
    |> String.slice(0, 200)
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(_), do: ""
end
