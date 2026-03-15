defmodule LoomkinWeb.ExploreLive do
  @moduledoc """
  Public-facing snippet explorer — browse, search, and filter public snippets.

  Accessible without authentication in deployed mode. Serves as the discovery
  surface for the Loomkin community.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Repo
  alias Loomkin.Social

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Explore",
        search_query: "",
        active_type: :all,
        sort_by: :recent
      )

    socket =
      if connected?(socket) do
        snippets =
          Social.list_public_snippets(limit: 20, sort: :recent)
          |> Repo.preload(:user)

        stream(socket, :snippets, snippets, dom_id: &snippet_dom_id/1)
      else
        stream(socket, :snippets, [], dom_id: &snippet_dom_id/1)
      end

    {:ok, socket}
  end

  defp snippet_dom_id(%{id: id}), do: "snippet-#{id}"

  def handle_params(params, _uri, socket) do
    type = parse_type(params["type"])
    sort = parse_sort(params["sort"])
    query = params["q"] || ""

    socket = assign(socket, active_type: type, sort_by: sort, search_query: query)

    socket =
      if connected?(socket) do
        snippets = fetch_snippets(query, type, sort)
        stream(socket, :snippets, snippets, reset: true, dom_id: &snippet_dom_id/1)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         explore_path(%{
           q: query,
           type: socket.assigns.active_type,
           sort: socket.assigns.sort_by
         })
     )}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         explore_path(%{
           q: socket.assigns.search_query,
           type: type,
           sort: socket.assigns.sort_by
         })
     )}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         explore_path(%{
           q: socket.assigns.search_query,
           type: socket.assigns.active_type,
           sort: sort
         })
     )}
  end

  defp fetch_snippets(query, type, sort) do
    opts = [limit: 20, sort: sort]
    opts = if type != :all, do: Keyword.put(opts, :type, type), else: opts

    snippets =
      if query != "" do
        Social.search_snippets(query, limit: 20)
      else
        Social.list_public_snippets(opts)
      end

    Repo.preload(snippets, :user)
  end

  defp parse_type("skill"), do: :skill
  defp parse_type("prompt"), do: :prompt
  defp parse_type("kin_agent"), do: :kin_agent
  defp parse_type("chat_log"), do: :chat_log
  defp parse_type(_), do: :all

  defp parse_sort("most_favorited"), do: :most_favorited
  defp parse_sort("most_forked"), do: :most_forked
  defp parse_sort(_), do: :recent

  defp explore_path(params) do
    query =
      params
      |> Enum.reject(fn {_k, v} -> v in [nil, "", :all, :recent] end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> Enum.into(%{})

    ~p"/explore?#{query}"
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 relative overflow-hidden">
      <div class="home-aurora" aria-hidden="true" />

      <nav class="relative z-20 border-b border-border-subtle bg-surface-0/80 backdrop-blur-md">
        <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-14">
            <div class="flex items-center gap-3">
              <.link navigate={~p"/"} class="text-brand font-semibold text-lg tracking-tight">
                Loomkin
              </.link>
              <span class="text-gray-600">/</span>
              <span class="text-gray-300 text-sm font-medium">Explore</span>
            </div>
            <%= if assigns[:current_scope] && assigns[:current_scope].user do %>
              <.link
                navigate={~p"/users/settings"}
                class="text-sm text-gray-400 hover:text-white transition-colors"
              >
                @{assigns[:current_scope].user.username}
              </.link>
            <% else %>
              <.link
                href={~p"/users/log-in"}
                class="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Log in
              </.link>
            <% end %>
          </div>
        </div>
      </nav>

      <div id="main-content" class="relative z-10 max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 pt-8 pb-16">
        <div class="text-center mb-10 animate-fade-in">
          <h1 class="text-3xl font-semibold text-white tracking-tight">
            Discover community snippets
          </h1>
          <p class="text-gray-400 mt-2 text-sm max-w-lg mx-auto">
            Skills, prompts, kin agents, and chat logs shared by the Loomkin community
          </p>
        </div>

        <div class="max-w-xl mx-auto mb-8 animate-fade-in" style="animation-delay: 50ms">
          <form id="explore-search" phx-submit="search" class="relative">
            <span class="hero-magnifying-glass-mini w-4 h-4 text-gray-500 absolute left-3.5 top-1/2 -translate-y-1/2" />
            <input
              type="text"
              name="q"
              value={@search_query}
              placeholder="Search snippets..."
              autocomplete="off"
              class={[
                "w-full bg-surface-1 border border-border-default rounded-xl",
                "pl-10 pr-4 py-3 text-sm text-gray-100 placeholder-gray-500",
                "focus:outline-none focus:ring-2 focus:ring-brand/50 focus:border-brand",
                "transition-colors"
              ]}
            />
          </form>
        </div>

        <div
          class="flex flex-wrap items-center justify-between gap-4 mb-6 animate-fade-in"
          style="animation-delay: 100ms"
        >
          <div class="flex items-center gap-2">
            <.type_filter_button type={:all} active={@active_type} label="All" />
            <.type_filter_button type={:skill} active={@active_type} label="Skills" />
            <.type_filter_button type={:prompt} active={@active_type} label="Prompts" />
            <.type_filter_button type={:kin_agent} active={@active_type} label="Kin Agents" />
            <.type_filter_button type={:chat_log} active={@active_type} label="Chat Logs" />
          </div>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span>Sort:</span>
            <.sort_button sort={:recent} active={@sort_by} label="Recent" />
            <.sort_button sort={:most_favorited} active={@sort_by} label="Most Favorited" />
            <.sort_button sort={:most_forked} active={@sort_by} label="Most Forked" />
          </div>
        </div>

        <div id="explore-snippets" phx-update="stream" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="hidden only:block col-span-full text-center py-16">
            <p class="text-gray-500">No snippets found</p>
            <p class="text-gray-600 text-xs mt-1">Try adjusting your search or filters</p>
          </div>
          <.explore_card :for={{id, snippet} <- @streams.snippets} id={id} snippet={snippet} />
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  defp type_filter_button(assigns) do
    ~H"""
    <button
      phx-click="filter_type"
      phx-value-type={@type}
      class={[
        "px-3 py-1.5 rounded-lg text-xs font-medium transition-all",
        if(@type == @active,
          do: "bg-brand/15 text-brand border border-brand/30",
          else:
            "bg-surface-2 text-gray-400 border border-border-subtle hover:border-border-hover hover:text-gray-300"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :sort, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  defp sort_button(assigns) do
    ~H"""
    <button
      phx-click="sort"
      phx-value-sort={@sort}
      class={[
        "px-2 py-1 rounded text-xs transition-colors",
        if(@sort == @active,
          do: "text-white font-medium",
          else: "text-gray-500 hover:text-gray-300"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :snippet, :map, required: true

  defp explore_card(assigns) do
    username =
      if Ecto.assoc_loaded?(assigns.snippet.user),
        do: assigns.snippet.user.username,
        else: "unknown"

    assigns = assign(assigns, :username, username)

    ~H"""
    <.link
      navigate={~p"/@#{@username}/#{@snippet.slug}"}
      id={@id}
      class={[
        "glass-subtle rounded-lg p-4 hover:border-border-hover transition-all",
        "hover-lift group block"
      ]}
    >
      <div class="flex items-start justify-between gap-3 mb-2">
        <div class="min-w-0">
          <h3 class="text-white text-sm font-medium truncate group-hover:text-brand transition-colors">
            {@snippet.title}
          </h3>
          <p class="text-gray-500 text-xs mt-0.5">
            by <span class="text-brand/80">@{@username}</span>
          </p>
        </div>
        <span class={[
          "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider shrink-0",
          snippet_badge_class(to_string(@snippet.type))
        ]}>
          {to_string(@snippet.type)}
        </span>
      </div>
      <p :if={@snippet.description} class="text-gray-400 text-xs line-clamp-2 mb-3">
        {@snippet.description}
      </p>
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-2 text-gray-500 text-xs">
          <span class="flex items-center gap-1">
            <span class="hero-star-mini w-3 h-3" /> {@snippet.favorite_count}
          </span>
          <span class="flex items-center gap-1">
            <span class="hero-arrow-path-mini w-3 h-3" /> {@snippet.fork_count}
          </span>
        </div>
        <div :if={@snippet.tags != []} class="flex items-center gap-1 ml-auto">
          <span
            :for={tag <- Enum.take(@snippet.tags, 3)}
            class="text-[10px] text-gray-500 bg-surface-3 px-1.5 py-0.5 rounded"
          >
            {tag}
          </span>
        </div>
      </div>
    </.link>
    """
  end

  defp snippet_badge_class("skill"), do: "bg-cyan-500/10 text-cyan-400 border border-cyan-500/20"

  defp snippet_badge_class("prompt"),
    do: "bg-amber-500/10 text-amber-400 border border-amber-500/20"

  defp snippet_badge_class("kin_agent"),
    do: "bg-violet-500/10 text-violet-400 border border-violet-500/20"

  defp snippet_badge_class("chat_log"),
    do: "bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"

  defp snippet_badge_class(_), do: "bg-gray-500/10 text-gray-400 border border-gray-500/20"
end
