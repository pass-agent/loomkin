defmodule LoomkinWeb.SocialPanelComponent do
  @moduledoc """
  Collapsible social side panel for WorkspaceLive.

  Three sections:
  - **Live Now** — followed users currently online via Presence
  - **Activity** — recent snippets/forks from followed users
  - **Notifications** — when someone favorites/forks your content

  Only renders in multi_tenant (deployed) mode.
  """
  use LoomkinWeb, :html

  attr :open, :boolean, required: true
  attr :live_friends, :list, required: true
  attr :activity, :list, required: true

  def social_panel(assigns) do
    ~H"""
    <%!-- Collapsed icon strip --%>
    <button
      :if={!@open}
      phx-click="toggle_social_panel"
      class="flex-shrink-0 flex flex-col items-center gap-2 py-3 px-1.5 border-l border-subtle bg-surface-1 hover:bg-surface-2 transition-colors"
      title="Open social panel"
    >
      <span class="hero-user-group-mini w-4 h-4 text-brand/70" />
      <span
        :if={@live_friends != []}
        class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"
      />
    </button>

    <%!-- Expanded panel --%>
    <div
      :if={@open}
      id="social-panel"
      class="flex-shrink-0 w-64 border-l border-subtle bg-surface-1/80 backdrop-blur-sm flex flex-col min-h-0 overflow-hidden"
    >
      <%!-- Header --%>
      <div class="flex items-center justify-between px-3 py-2 border-b border-subtle">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-gray-400">
          Social
        </span>
        <button
          phx-click="toggle_social_panel"
          class="text-gray-500 hover:text-gray-300 transition-colors"
          aria-label="Close social panel"
        >
          <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
        </button>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%!-- Live Now --%>
        <div class="px-3 pt-3 pb-2">
          <h3 class="text-[10px] font-semibold uppercase tracking-wider text-gray-500 mb-2">
            Live Now
          </h3>
          <%= if @live_friends == [] do %>
            <p class="text-gray-600 text-[11px]">No friends online</p>
          <% else %>
            <div class="space-y-1.5">
              <.live_friend_row :for={friend <- @live_friends} friend={friend} />
            </div>
          <% end %>
        </div>

        <div class="mx-3 border-t border-subtle" />

        <%!-- Activity --%>
        <div class="px-3 pt-3 pb-2">
          <h3 class="text-[10px] font-semibold uppercase tracking-wider text-gray-500 mb-2">
            Activity
          </h3>
          <%= if @activity == [] do %>
            <p class="text-gray-600 text-[11px]">No recent activity</p>
          <% else %>
            <div class="space-y-2">
              <.activity_row :for={snippet <- @activity} snippet={snippet} />
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :friend, :map, required: true

  defp live_friend_row(assigns) do
    page = assigns.friend[:page]
    session_id = assigns.friend[:session_id]

    status_text =
      cond do
        page == :workspace && session_id -> "in session"
        page == :workspace -> "workspace"
        true -> "online"
      end

    assigns = assign(assigns, status_text: status_text)

    ~H"""
    <div class="flex items-center gap-2 py-1 px-1.5 rounded-md hover:bg-surface-2 transition-colors group">
      <span class="relative flex-shrink-0">
        <%= if @friend[:avatar_url] do %>
          <img
            src={@friend.avatar_url}
            class="w-5 h-5 rounded-full object-cover"
            alt={@friend[:username]}
          />
        <% else %>
          <span class="w-5 h-5 rounded-full bg-surface-3 flex items-center justify-center text-[9px] font-bold text-gray-400">
            {((@friend[:username] || "?") |> String.first() || "?") |> String.upcase()}
          </span>
        <% end %>
        <span class="absolute -bottom-0.5 -right-0.5 w-2 h-2 rounded-full bg-emerald-400 border border-surface-1" />
      </span>
      <div class="min-w-0 flex-1">
        <span class="text-[11px] text-gray-300 font-medium truncate block">
          @{@friend[:username]}
        </span>
        <span class="text-[10px] text-gray-600">{@status_text}</span>
      </div>
    </div>
    """
  end

  attr :snippet, :map, required: true

  defp activity_row(assigns) do
    username =
      if Ecto.assoc_loaded?(assigns.snippet.user),
        do: assigns.snippet.user.username,
        else: "unknown"

    time_ago = time_ago(assigns.snippet.inserted_at)
    assigns = assign(assigns, username: username, time_ago: time_ago)

    ~H"""
    <div class="py-1">
      <div class="text-[11px]">
        <span class="text-brand/80">@{@username}</span>
        <span class="text-gray-500">published</span>
      </div>
      <div class="text-[11px] text-gray-300 truncate">{@snippet.title}</div>
      <div class="flex items-center gap-2 text-[10px] text-gray-600 mt-0.5">
        <span class="flex items-center gap-0.5">
          <span class="hero-star-mini w-2.5 h-2.5" /> {@snippet.favorite_count}
        </span>
        <span>{@time_ago}</span>
      </div>
    </div>
    """
  end

  defp time_ago(nil), do: ""

  defp time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
