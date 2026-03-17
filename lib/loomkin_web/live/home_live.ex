defmodule LoomkinWeb.HomeLive do
  @moduledoc """
  Social dashboard homepage for deployed (multi_tenant) mode.
  In local mode, redirects to the project picker.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Repo
  alias Loomkin.Session.Persistence
  alias Loomkin.Social

  def mount(_params, _session, socket) do
    unless Application.get_env(:loomkin, :multi_tenant) do
      {:ok, push_navigate(socket, to: ~p"/projects")}
    else
      user = socket.assigns.current_scope && socket.assigns.current_scope.user

      socket =
        socket
        |> assign(
          page_title: "Home",
          user: user,
          snippet_counts: %{skills: 0, prompts: 0, kin_agents: 0, chat_logs: 0},
          total_snippets: 0,
          recent_sessions: [],
          has_content: false
        )
        |> stream(:projects, [], dom_id: &project_dom_id/1)
        |> stream(:community_feed, [], dom_id: &feed_dom_id/1)
        |> stream(:trending, [], dom_id: &trending_dom_id/1)
        |> stream(:favorites, [], dom_id: &favorite_dom_id/1)

      socket =
        if connected?(socket) do
          projects = Persistence.list_projects(user: user)

          {snippet_counts, favorites, recent_sessions} =
            if user do
              counts = Social.snippet_counts_by_type(user)

              favs =
                Social.list_favorites(user, limit: 5)
                |> Enum.map(fn fav -> fav.snippet end)
                |> Repo.preload(:user)

              sessions = Persistence.list_sessions(user: user, limit: 5)

              {counts, favs, sessions}
            else
              {%{skills: 0, prompts: 0, kin_agents: 0, chat_logs: 0}, [], []}
            end

          community_feed =
            Social.list_public_snippets(limit: 10, sort: :recent)
            |> Repo.preload(:user)

          trending =
            Social.trending_snippets(limit: 5)
            |> Repo.preload(:user)

          total_snippets =
            snippet_counts.skills + snippet_counts.prompts + snippet_counts.kin_agents +
              snippet_counts.chat_logs

          has_content = total_snippets > 0 or community_feed != [] or projects != []

          socket
          |> assign(
            snippet_counts: snippet_counts,
            total_snippets: total_snippets,
            recent_sessions: recent_sessions,
            has_content: has_content
          )
          |> stream(:projects, projects, dom_id: &project_dom_id/1, reset: true)
          |> stream(:community_feed, community_feed, dom_id: &feed_dom_id/1, reset: true)
          |> stream(:trending, trending, dom_id: &trending_dom_id/1, reset: true)
          |> stream(:favorites, favorites, dom_id: &favorite_dom_id/1, reset: true)
        else
          socket
        end

      {:ok, socket}
    end
  end

  defp feed_dom_id(%{id: id}), do: "home-feed-#{id}"
  defp trending_dom_id(%{id: id}), do: "home-trending-#{id}"
  defp favorite_dom_id(%{id: id}), do: "home-fav-#{id}"

  defp project_dom_id(%{project_path: path}) do
    "home-project-" <> Base.url_encode64(path, padding: false)
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 relative overflow-hidden">
      <div class="home-aurora" aria-hidden="true" />

      <.top_nav current_scope={assigns[:current_scope]} />

      <%= if @has_content do %>
        <.populated_layout
          user={@user}
          total_snippets={@total_snippets}
          snippet_counts={@snippet_counts}
          recent_sessions={@recent_sessions}
          streams={@streams}
        />
      <% else %>
        <.empty_state user={@user} />
      <% end %>
    </div>
    """
  end

  # ── Top Navigation ──────────────────────────────────────────────────

  attr :current_scope, :any, default: nil

  defp top_nav(assigns) do
    ~H"""
    <nav class="sticky top-0 z-30 border-b border-border-subtle bg-surface-0/90 backdrop-blur-xl">
      <div class="max-w-6xl mx-auto px-5">
        <div class="flex items-center justify-between h-12">
          <div class="flex items-center gap-6">
            <%!-- Logo --%>
            <.link navigate={~p"/"} class="flex items-center gap-2 group">
              <svg
                width="24"
                height="24"
                viewBox="0 0 52 52"
                fill="none"
                class="opacity-80 group-hover:opacity-100 transition-opacity"
              >
                <ellipse
                  cx="26"
                  cy="26"
                  rx="18"
                  ry="8"
                  transform="rotate(-30 26 26)"
                  stroke="#7C3AED"
                  stroke-width="2.5"
                  fill="none"
                />
                <ellipse
                  cx="26"
                  cy="26"
                  rx="18"
                  ry="8"
                  transform="rotate(30 26 26)"
                  stroke="#22d3ee"
                  stroke-width="2.5"
                  fill="none"
                  opacity="0.6"
                />
                <ellipse
                  cx="26"
                  cy="26"
                  rx="18"
                  ry="8"
                  transform="rotate(90 26 26)"
                  stroke="#a78bfa"
                  stroke-width="2.5"
                  fill="none"
                  opacity="0.5"
                />
              </svg>
              <span class="text-sm font-light text-gray-300 tracking-wide hidden sm:inline">
                loom<span class="font-semibold text-brand">kin</span>
              </span>
            </.link>
            <%!-- Nav links --%>
            <div class="flex items-center gap-1">
              <.link
                navigate={~p"/explore"}
                class="px-2.5 py-1 rounded-md text-xs text-gray-500 hover:text-gray-200 hover:bg-surface-2 transition-all"
              >
                Explore
              </.link>
              <%= if @current_scope && @current_scope.user do %>
                <.link
                  navigate={~p"/projects"}
                  class="px-2.5 py-1 rounded-md text-xs text-gray-500 hover:text-gray-200 hover:bg-surface-2 transition-all"
                >
                  Projects
                </.link>
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <%= if @current_scope && @current_scope.user do %>
              <.link
                navigate={~p"/snippets/new"}
                class={[
                  "px-2.5 py-1 rounded-md text-xs font-medium",
                  "bg-brand/10 text-brand border border-brand/20",
                  "hover:bg-brand/20 hover:border-brand/30 transition-all"
                ]}
              >
                + New
              </.link>
              <.link
                navigate={~p"/users/settings"}
                class="w-7 h-7 rounded-full bg-surface-3 border border-border-subtle hover:border-border-hover flex items-center justify-center transition-all"
              >
                <span class="text-[10px] font-bold text-gray-400">
                  {((@current_scope.user.username || @current_scope.user.email || "?")
                    |> String.first() || "?")
                  |> String.upcase()}
                </span>
              </.link>
            <% else %>
              <.link
                href={~p"/users/log-in"}
                class="px-3 py-1 rounded-md text-xs text-gray-400 hover:text-white transition-colors"
              >
                Log in
              </.link>
              <.link
                href={~p"/users/register"}
                class={[
                  "px-3 py-1 rounded-md text-xs font-medium",
                  "bg-brand text-white hover:bg-violet-500 transition-colors"
                ]}
              >
                Sign up
              </.link>
            <% end %>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  # ── Empty State — Invitation, not a graveyard ──────────────────────

  attr :user, :any, default: nil

  defp empty_state(assigns) do
    ~H"""
    <div class="relative z-10 max-w-6xl mx-auto px-5">
      <%!-- Hero --%>
      <div class="pt-20 pb-16 text-center">
        <div class="inline-block mb-6">
          <svg
            width="64"
            height="64"
            viewBox="0 0 52 52"
            fill="none"
            class="drop-shadow-[0_0_20px_rgba(124,58,237,0.25)]"
          >
            <ellipse
              cx="26"
              cy="26"
              rx="18"
              ry="8"
              transform="rotate(-30 26 26)"
              stroke="url(#eh1)"
              stroke-width="1.5"
              fill="none"
            />
            <ellipse
              cx="26"
              cy="26"
              rx="18"
              ry="8"
              transform="rotate(30 26 26)"
              stroke="url(#eh2)"
              stroke-width="1.5"
              fill="none"
            />
            <ellipse
              cx="26"
              cy="26"
              rx="18"
              ry="8"
              transform="rotate(90 26 26)"
              stroke="url(#eh3)"
              stroke-width="1.5"
              fill="none"
            />
            <defs>
              <linearGradient id="eh1" x1="8" y1="18" x2="44" y2="34" gradientUnits="userSpaceOnUse">
                <stop stop-color="#7C3AED" />
                <stop offset="1" stop-color="#a78bfa" />
              </linearGradient>
              <linearGradient
                id="eh2"
                x1="8"
                y1="34"
                x2="44"
                y2="18"
                gradientUnits="userSpaceOnUse"
              >
                <stop stop-color="#22d3ee" stop-opacity="0.6" />
                <stop offset="1" stop-color="#7C3AED" />
              </linearGradient>
              <linearGradient
                id="eh3"
                x1="26"
                y1="8"
                x2="26"
                y2="44"
                gradientUnits="userSpaceOnUse"
              >
                <stop stop-color="#a78bfa" stop-opacity="0.5" />
                <stop offset="1" stop-color="#22d3ee" stop-opacity="0.7" />
              </linearGradient>
            </defs>
          </svg>
        </div>
        <h1 class="text-3xl font-light text-white tracking-tight mb-3">
          Welcome to <span class="font-semibold">Loomkin</span>
        </h1>
        <p class="text-gray-500 text-sm max-w-md mx-auto leading-relaxed">
          Share skills, prompts, and agent configurations with the community.
          Fork what works. Build on what others have learned.
        </p>
      </div>

      <%!-- Quick actions — the whole point of an empty state --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 max-w-2xl mx-auto mb-16">
        <.empty_action_card
          icon="hero-bolt"
          title="Share a skill"
          description="Import from .agents/skills/ or write one from scratch"
          href={if @user, do: ~p"/snippets/new", else: ~p"/users/register"}
          color="cyan"
        />
        <.empty_action_card
          icon="hero-chat-bubble-bottom-center-text"
          title="Save a prompt"
          description="Capture system prompts and templates that work"
          href={if @user, do: ~p"/snippets/new", else: ~p"/users/register"}
          color="amber"
        />
        <.empty_action_card
          icon="hero-cpu-chip"
          title="Publish a kin agent"
          description="Share agent configs with role, tools, and personality"
          href={if @user, do: ~p"/snippets/new", else: ~p"/users/register"}
          color="violet"
        />
      </div>

      <%!-- Explore CTA --%>
      <div class="text-center pb-20">
        <.link
          navigate={~p"/explore"}
          class={[
            "inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-sm",
            "glass hover:border-border-hover transition-all",
            "text-gray-400 hover:text-white"
          ]}
        >
          <span class="hero-magnifying-glass w-4 h-4" /> Browse community snippets
        </.link>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :href, :string, required: true
  attr :color, :string, required: true

  defp empty_action_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "glass rounded-xl p-5 group hover-lift press-down text-left",
        "hover:border-border-hover transition-all block"
      ]}
    >
      <div class={[
        "w-9 h-9 rounded-lg flex items-center justify-center mb-3",
        action_icon_bg(@color)
      ]}>
        <span class={[@icon, "w-5 h-5", action_icon_color(@color)]} />
      </div>
      <h3 class="text-sm font-medium text-white mb-1 group-hover:text-brand transition-colors">
        {@title}
      </h3>
      <p class="text-xs text-gray-600 leading-relaxed">{@description}</p>
    </.link>
    """
  end

  defp action_icon_bg("cyan"), do: "bg-cyan-500/10 border border-cyan-500/15"
  defp action_icon_bg("amber"), do: "bg-amber-500/10 border border-amber-500/15"
  defp action_icon_bg("violet"), do: "bg-violet-500/10 border border-violet-500/15"
  defp action_icon_bg(_), do: "bg-surface-3 border border-border-subtle"

  defp action_icon_color("cyan"), do: "text-cyan-400"
  defp action_icon_color("amber"), do: "text-amber-400"
  defp action_icon_color("violet"), do: "text-violet-400"
  defp action_icon_color(_), do: "text-gray-400"

  # ── Populated Layout — Dense, feed-first ───────────────────────────

  attr :user, :any, default: nil
  attr :total_snippets, :integer, required: true
  attr :snippet_counts, :map, required: true
  attr :recent_sessions, :list, required: true
  attr :streams, :map, required: true

  defp populated_layout(assigns) do
    ~H"""
    <div class="relative z-10 max-w-6xl mx-auto px-5 py-6">
      <div class="grid grid-cols-1 lg:grid-cols-12 gap-6">
        <%!-- Left sidebar — compact, functional --%>
        <aside class="lg:col-span-3 space-y-5">
          <%!-- User card --%>
          <div :if={@user} class="animate-fade-in">
            <div class="flex items-center gap-2.5 mb-4">
              <div class="w-8 h-8 rounded-full bg-brand/15 border border-brand/25 flex items-center justify-center">
                <span class="text-xs font-bold text-brand">
                  {((@user.username || @user.email || "?") |> String.first() || "?")
                  |> String.upcase()}
                </span>
              </div>
              <div class="min-w-0">
                <p class="text-sm font-medium text-white truncate">
                  {@user.username || @user.email}
                </p>
                <p class="text-[10px] text-gray-600">{@total_snippets} snippets</p>
              </div>
            </div>
          </div>

          <%!-- Snippet counts — horizontal compact --%>
          <div class="animate-fade-in" style="animation-delay: 50ms">
            <div class="grid grid-cols-2 gap-1.5">
              <.stat_pill
                count={@snippet_counts.skills}
                label="skills"
                icon="hero-bolt-mini"
                color="cyan"
              />
              <.stat_pill
                count={@snippet_counts.prompts}
                label="prompts"
                icon="hero-chat-bubble-bottom-center-text-mini"
                color="amber"
              />
              <.stat_pill
                count={@snippet_counts.kin_agents}
                label="agents"
                icon="hero-cpu-chip-mini"
                color="violet"
              />
              <.stat_pill
                count={@snippet_counts.chat_logs}
                label="chats"
                icon="hero-document-text-mini"
                color="emerald"
              />
            </div>
          </div>

          <%!-- Projects --%>
          <div class="animate-fade-in" style="animation-delay: 100ms">
            <h3 class="text-[10px] font-semibold text-gray-600 uppercase tracking-widest mb-2">
              Projects
            </h3>
            <div id="home-projects" phx-update="stream" class="space-y-0.5">
              <div class="hidden only:block py-3">
                <p class="text-xs text-gray-600">No projects yet</p>
              </div>
              <.link
                :for={{id, project} <- @streams.projects}
                id={id}
                navigate={~p"/sessions/new?#{%{project_path: project.project_path}}"}
                class={[
                  "flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md group",
                  "hover:bg-surface-2 transition-colors"
                ]}
              >
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-500/50 shrink-0" />
                <span class="text-xs text-gray-400 group-hover:text-white truncate transition-colors">
                  {Path.basename(project.project_path)}
                </span>
                <span class="text-[10px] text-gray-700 ml-auto tabular-nums shrink-0">
                  {project.session_count}
                </span>
              </.link>
            </div>
          </div>

          <%!-- Favorites --%>
          <div class="animate-fade-in" style="animation-delay: 150ms">
            <h3 class="text-[10px] font-semibold text-gray-600 uppercase tracking-widest mb-2">
              Starred
            </h3>
            <div id="home-favorites" phx-update="stream" class="space-y-0.5">
              <div class="hidden only:block py-3">
                <p class="text-xs text-gray-600">No favorites yet</p>
              </div>
              <.link
                :for={{id, fav} <- @streams.favorites}
                id={id}
                navigate={~p"/@#{fav.user.username}/#{fav.slug}"}
                class="flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-surface-2 transition-colors group"
              >
                <span class="hero-star-solid w-3 h-3 text-amber-500/60 shrink-0" />
                <span class="text-xs text-gray-400 group-hover:text-white truncate transition-colors">
                  {fav.title}
                </span>
              </.link>
            </div>
          </div>

          <%!-- Recent sessions --%>
          <div :if={@recent_sessions != []} class="animate-fade-in" style="animation-delay: 200ms">
            <h3 class="text-[10px] font-semibold text-gray-600 uppercase tracking-widest mb-2">
              Recent
            </h3>
            <div class="space-y-0.5">
              <.link
                :for={session <- @recent_sessions}
                navigate={~p"/sessions/#{session.id}"}
                class="flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-surface-2 transition-colors group"
              >
                <span class={[
                  "w-1.5 h-1.5 rounded-full shrink-0",
                  if(session.status == :active, do: "bg-emerald-400", else: "bg-gray-700")
                ]} />
                <span class="text-xs text-gray-400 group-hover:text-white truncate transition-colors">
                  {session.title || "Untitled"}
                </span>
                <span class="text-[10px] text-gray-700 ml-auto shrink-0">
                  {format_relative_time(session.updated_at)}
                </span>
              </.link>
            </div>
          </div>
        </aside>

        <%!-- Main feed — the center of gravity --%>
        <main class="lg:col-span-6 min-w-0">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-widest">Feed</h2>
            <.link
              navigate={~p"/explore"}
              class="text-[10px] text-gray-600 hover:text-gray-400 transition-colors"
            >
              View all →
            </.link>
          </div>

          <div id="home-community-feed" phx-update="stream" class="space-y-2">
            <div class="hidden only:block glass rounded-xl p-8 text-center">
              <p class="text-gray-500 text-sm mb-2">No public snippets yet</p>
              <p class="text-gray-600 text-xs mb-4">
                Be the first to share something with the community
              </p>
              <.link
                navigate={if @user, do: ~p"/snippets/new", else: ~p"/users/register"}
                class={[
                  "inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-xs font-medium",
                  "bg-brand/10 text-brand border border-brand/20",
                  "hover:bg-brand/20 transition-all"
                ]}
              >
                <span class="hero-plus-mini w-3.5 h-3.5" /> Create a snippet
              </.link>
            </div>
            <.feed_card :for={{id, snippet} <- @streams.community_feed} id={id} snippet={snippet} />
          </div>
        </main>

        <%!-- Right sidebar — trending --%>
        <aside class="lg:col-span-3">
          <div class="sticky top-16">
            <div class="animate-fade-in" style="animation-delay: 100ms">
              <h3 class="text-[10px] font-semibold text-gray-600 uppercase tracking-widest mb-3">
                Trending
              </h3>
              <div id="home-trending" phx-update="stream" class="space-y-1">
                <div class="hidden only:block py-2">
                  <p class="text-xs text-gray-600">Nothing trending yet</p>
                </div>
                <.trending_item
                  :for={{id, item} <- @streams.trending}
                  id={id}
                  item={item}
                />
              </div>
            </div>

            <%!-- Quick create --%>
            <div :if={@user} class="mt-6 animate-fade-in" style="animation-delay: 150ms">
              <h3 class="text-[10px] font-semibold text-gray-600 uppercase tracking-widest mb-3">
                Create
              </h3>
              <div class="space-y-1">
                <.link
                  navigate={~p"/snippets/new"}
                  class="flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-surface-2 transition-colors group text-xs text-gray-500 hover:text-white"
                >
                  <span class="hero-bolt-mini w-3.5 h-3.5 text-cyan-400/60" /> New skill
                </.link>
                <.link
                  navigate={~p"/snippets/new"}
                  class="flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-surface-2 transition-colors group text-xs text-gray-500 hover:text-white"
                >
                  <span class="hero-chat-bubble-bottom-center-text-mini w-3.5 h-3.5 text-amber-400/60" />
                  New prompt
                </.link>
                <.link
                  navigate={~p"/snippets/new"}
                  class="flex items-center gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-surface-2 transition-colors group text-xs text-gray-500 hover:text-white"
                >
                  <span class="hero-cpu-chip-mini w-3.5 h-3.5 text-violet-400/60" /> New kin agent
                </.link>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  # ── Stat Pill ──────────────────────────────────────────────────────

  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true

  defp stat_pill(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-1.5 px-2 py-1.5 rounded-md",
      "bg-surface-1 border border-border-subtle"
    ]}>
      <span class={[@icon, "w-3 h-3", action_icon_color(@color)]} />
      <span class="text-xs tabular-nums text-gray-300 font-medium">{@count}</span>
      <span class="text-[10px] text-gray-600">{@label}</span>
    </div>
    """
  end

  # ── Feed Card ──────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :snippet, :map, required: true

  defp feed_card(assigns) do
    username =
      if Ecto.assoc_loaded?(assigns.snippet.user),
        do: assigns.snippet.user.username,
        else: "unknown"

    assigns = assign(assigns, :username, username)

    ~H"""
    <div
      id={@id}
      class={[
        "glass-subtle rounded-lg px-4 py-3.5 group",
        "hover:border-border-hover transition-all"
      ]}
    >
      <div class="flex items-start gap-3">
        <div class="w-7 h-7 rounded-full bg-surface-3 border border-border-subtle flex items-center justify-center shrink-0 mt-0.5">
          <span class="text-[10px] font-medium text-gray-500">
            {((@username || "?") |> String.first() || "?") |> String.upcase()}
          </span>
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-1.5">
            <span class="text-xs font-medium text-brand">@{@username}</span>
            <span class="text-[10px] text-gray-700">·</span>
            <span class="text-[10px] text-gray-700">
              {format_relative_time(@snippet.inserted_at)}
            </span>
          </div>
          <p class="text-sm text-gray-200 mt-0.5 group-hover:text-white transition-colors">
            {@snippet.title}
          </p>
          <p
            :if={@snippet.description}
            class="text-xs text-gray-600 mt-1 line-clamp-2 leading-relaxed"
          >
            {@snippet.description}
          </p>
          <div class="flex items-center gap-3 mt-2">
            <.type_tag type={to_string(@snippet.type)} />
            <div class="flex items-center gap-2.5 text-[10px] text-gray-600 ml-auto">
              <span class="flex items-center gap-0.5">
                <span class="hero-star-mini w-3 h-3" /> {@snippet.favorite_count}
              </span>
              <span class="flex items-center gap-0.5">
                <span class="hero-arrow-path-mini w-3 h-3" /> {@snippet.fork_count}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Type Tag ───────────────────────────────────────────────────────

  attr :type, :string, required: true

  defp type_tag(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-1.5 py-0.5 rounded text-[9px] font-semibold uppercase tracking-wider",
      type_tag_class(@type)
    ]}>
      {@type |> String.replace("_", " ")}
    </span>
    """
  end

  defp type_tag_class("skill"), do: "bg-cyan-500/8 text-cyan-500 border border-cyan-500/15"
  defp type_tag_class("prompt"), do: "bg-amber-500/8 text-amber-500 border border-amber-500/15"

  defp type_tag_class("kin_agent"),
    do: "bg-violet-500/8 text-violet-500 border border-violet-500/15"

  defp type_tag_class("chat_log"),
    do: "bg-emerald-500/8 text-emerald-500 border border-emerald-500/15"

  defp type_tag_class(_), do: "bg-gray-500/8 text-gray-500 border border-gray-500/15"

  # ── Trending Item ──────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :item, :map, required: true

  defp trending_item(assigns) do
    username =
      if Ecto.assoc_loaded?(assigns.item.user), do: assigns.item.user.username, else: "unknown"

    assigns = assign(assigns, :username, username)

    ~H"""
    <div
      id={@id}
      class="flex items-center gap-2.5 px-2 py-2 -mx-2 rounded-md hover:bg-surface-2 transition-colors group"
    >
      <div class="min-w-0 flex-1">
        <p class="text-xs text-gray-300 truncate group-hover:text-white transition-colors">
          {@item.title}
        </p>
        <p class="text-[10px] text-gray-700">@{@username}</p>
      </div>
      <span class="flex items-center gap-0.5 text-[10px] text-amber-500/60 shrink-0">
        <span class="hero-star-solid w-2.5 h-2.5" /> {@item.favorite_count}
      </span>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86400)}d"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end
end
