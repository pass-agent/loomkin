defmodule LoomkinWeb.ProfileLive do
  @moduledoc """
  Public user profile page — displays a user's public snippets, bio,
  and aggregate social stats (followers, following, snippet counts).

  Route: `/@:username`
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Accounts
  alias Loomkin.Repo
  alias Loomkin.Social

  def mount(%{"username" => username}, _session, socket) do
    case Accounts.get_user_by_username(username) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "User not found.")
         |> push_navigate(to: "/explore")}

      profile_user ->
        socket =
          if connected?(socket) do
            snippets =
              Social.list_user_snippets(profile_user, visibility: :public, limit: 30)
              |> Repo.preload(:user)

            follower_count = Social.follower_count(profile_user)
            following_count = Social.following_count(profile_user)
            counts = Social.snippet_counts_by_type(profile_user)

            socket
            |> assign(
              follower_count: follower_count,
              following_count: following_count,
              snippet_counts: counts
            )
            |> stream(:snippets, snippets, dom_id: &snippet_dom_id/1)
          else
            socket
            |> assign(
              follower_count: 0,
              following_count: 0,
              snippet_counts: %{skills: 0, prompts: 0, kin_agents: 0, chat_logs: 0}
            )
            |> stream(:snippets, [], dom_id: &snippet_dom_id/1)
          end

        socket =
          assign(socket,
            page_title: "@#{username}",
            profile_user: profile_user,
            active_type: :all
          )

        {:ok, socket}
    end
  end

  defp snippet_dom_id(%{id: id}), do: "profile-snippet-#{id}"

  def handle_event("filter_type", %{"type" => type}, socket) do
    type_atom = parse_type(type)

    opts = [visibility: :public, limit: 30]
    opts = if type_atom != :all, do: Keyword.put(opts, :type, type_atom), else: opts

    snippets =
      Social.list_user_snippets(socket.assigns.profile_user, opts)
      |> Repo.preload(:user)

    socket =
      socket
      |> assign(active_type: type_atom)
      |> stream(:snippets, snippets, reset: true, dom_id: &snippet_dom_id/1)

    {:noreply, socket}
  end

  defp parse_type("skill"), do: :skill
  defp parse_type("prompt"), do: :prompt
  defp parse_type("kin_agent"), do: :kin_agent
  defp parse_type("chat_log"), do: :chat_log
  defp parse_type(_), do: :all

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 relative overflow-hidden">
      <div class="home-aurora" aria-hidden="true" />

      <%!-- Nav --%>
      <nav class="relative z-20 border-b border-border-subtle bg-surface-0/80 backdrop-blur-md">
        <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-14">
            <div class="flex items-center gap-3">
              <.link navigate={~p"/"} class="text-brand font-semibold text-lg tracking-tight">
                Loomkin
              </.link>
              <span class="text-gray-600">/</span>
              <span class="text-gray-300 text-sm font-medium">@{@profile_user.username}</span>
            </div>
            <.link
              navigate="/explore"
              class="text-sm text-gray-400 hover:text-white transition-colors"
            >
              Explore
            </.link>
          </div>
        </div>
      </nav>

      <div id="main-content" class="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 pt-8 pb-16">
        <%!-- Profile header --%>
        <div class="flex items-start gap-5 mb-10 animate-fade-in">
          <%!-- Avatar --%>
          <div class="w-16 h-16 rounded-full bg-surface-3 border-2 border-border-default flex items-center justify-center shrink-0">
            <%= if @profile_user.avatar_url do %>
              <img
                src={@profile_user.avatar_url}
                alt={@profile_user.display_name}
                class="w-full h-full rounded-full object-cover"
              />
            <% else %>
              <span class="text-2xl font-bold text-gray-400">
                {String.first(@profile_user.username) |> String.upcase()}
              </span>
            <% end %>
          </div>
          <div class="flex-1 min-w-0">
            <h1 class="text-xl font-semibold text-white">
              {@profile_user.display_name || @profile_user.username}
            </h1>
            <p class="text-brand text-sm">@{@profile_user.username}</p>
            <div class="flex items-center gap-4 mt-3 text-xs text-gray-400">
              <span class="flex items-center gap-1.5">
                <span class="text-white font-medium">{@follower_count}</span> followers
              </span>
              <span class="flex items-center gap-1.5">
                <span class="text-white font-medium">{@following_count}</span> following
              </span>
              <span class="flex items-center gap-1.5">
                <span class="text-white font-medium">
                  {@snippet_counts.skills + @snippet_counts.prompts + @snippet_counts.kin_agents +
                    @snippet_counts.chat_logs}
                </span>
                snippets
              </span>
            </div>
          </div>
        </div>

        <%!-- Type filter tabs --%>
        <div class="flex items-center gap-2 mb-6 animate-fade-in" style="animation-delay: 50ms">
          <.profile_tab type={:all} active={@active_type} label="All" />
          <.profile_tab
            type={:skill}
            active={@active_type}
            label={"Skills (#{@snippet_counts.skills})"}
          />
          <.profile_tab
            type={:prompt}
            active={@active_type}
            label={"Prompts (#{@snippet_counts.prompts})"}
          />
          <.profile_tab
            type={:kin_agent}
            active={@active_type}
            label={"Kin Agents (#{@snippet_counts.kin_agents})"}
          />
          <.profile_tab
            type={:chat_log}
            active={@active_type}
            label={"Chat Logs (#{@snippet_counts.chat_logs})"}
          />
        </div>

        <%!-- Snippet list --%>
        <div id="profile-snippets" phx-update="stream" class="space-y-3">
          <div class="hidden only:block text-center py-12">
            <p class="text-gray-500">No public snippets yet</p>
          </div>
          <.profile_snippet_card
            :for={{id, snippet} <- @streams.snippets}
            id={id}
            snippet={snippet}
            username={@profile_user.username}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  defp profile_tab(assigns) do
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

  attr :id, :string, required: true
  attr :snippet, :map, required: true
  attr :username, :string, required: true

  defp profile_snippet_card(assigns) do
    ~H"""
    <.link
      navigate={"/@#{@username}/#{@snippet.slug}"}
      id={@id}
      class={[
        "glass-subtle rounded-lg p-4 hover:border-border-hover transition-all block",
        "hover-lift group cursor-pointer"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <h3 class="text-white text-sm font-medium truncate group-hover:text-brand transition-colors">
            {@snippet.title}
          </h3>
          <p :if={@snippet.description} class="text-gray-500 text-xs mt-1 line-clamp-2">
            {@snippet.description}
          </p>
        </div>
        <span class={[
          "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider shrink-0",
          snippet_badge_class(to_string(@snippet.type))
        ]}>
          {to_string(@snippet.type)}
        </span>
      </div>
      <div class="flex items-center gap-3 mt-2.5">
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
