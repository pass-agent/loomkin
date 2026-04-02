defmodule LoomkinWeb.HomeLive do
  @moduledoc """
  Landing page. In local mode, redirects to the project picker.
  In multi-tenant mode, shows the user's accessible vaults.
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Vault

  def mount(_params, _session, socket) do
    unless Application.get_env(:loomkin, :multi_tenant) do
      {:ok, push_navigate(socket, to: ~p"/projects")}
    else
      user = socket.assigns.current_scope && socket.assigns.current_scope.user

      vaults =
        if user do
          load_user_vaults(user)
        else
          []
        end

      {:ok,
       assign(socket,
         page_title: "Loomkin",
         user: user,
         vaults: vaults
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen" style="background: var(--surface-0);">
      <div class="home-aurora" aria-hidden="true" />

      <%!-- Top nav --%>
      <nav
        class="sticky top-0 z-30 border-b bg-surface-0/90 backdrop-blur-xl"
        style="border-color: var(--border-subtle);"
      >
        <div class="max-w-5xl mx-auto px-5">
          <div class="flex items-center justify-between h-12">
            <.link navigate={~p"/"} class="flex items-center gap-2 group">
              <svg
                width="24"
                height="24"
                viewBox="0 0 32 32"
                fill="none"
                class="opacity-80 group-hover:opacity-100 transition-opacity"
              >
                <%!-- Nestled body — plump, rounded, tucked in --%>
                <path
                  d="M16 3C9.5 3 5.5 7.5 5.5 13.5c0 3.5 1.5 6.5 3.5 8.5C11 24 13 26 16 26s5-2 7-4c2-2 3.5-5 3.5-8.5C26.5 7.5 22.5 3 16 3z"
                  fill="var(--surface-2)"
                  stroke="var(--brand)"
                  stroke-width="1.2"
                />
                <%!-- Ear tufts — small, cozy --%>
                <path
                  d="M11 5.5L9.5 2.5M21 5.5l1.5-3"
                  stroke="var(--brand)"
                  stroke-width="1.2"
                  stroke-linecap="round"
                />
                <%!-- Tucked wing hints --%>
                <path
                  d="M8 16c1.5 2 2.5 4.5 3 7M24 16c-1.5 2-2.5 4.5-3 7"
                  stroke="var(--brand)"
                  stroke-width="0.8"
                  stroke-linecap="round"
                  opacity="0.35"
                />
                <%!-- Chest feather lines — nestled texture --%>
                <path
                  d="M13 20c1-.6 2-.9 3-.9s2 .3 3 .9M13.5 22c.8-.4 1.6-.6 2.5-.6s1.7.2 2.5.6"
                  stroke="var(--brand)"
                  stroke-width="0.7"
                  stroke-linecap="round"
                  opacity="0.25"
                />
                <%!-- Left eye --%>
                <circle
                  cx="12"
                  cy="13"
                  r="3.5"
                  fill="var(--surface-0)"
                  stroke="var(--accent-amber)"
                  stroke-width="0.8"
                />
                <circle cx="12.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
                <%!-- Right eye --%>
                <circle
                  cx="20"
                  cy="13"
                  r="3.5"
                  fill="var(--surface-0)"
                  stroke="var(--accent-amber)"
                  stroke-width="0.8"
                />
                <circle cx="20.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
                <%!-- Beak — small, tucked --%>
                <path
                  d="M15 17l1 1.5 1-1.5"
                  stroke="var(--accent-peach)"
                  stroke-width="1"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
              <span
                class="text-sm font-light tracking-wide hidden sm:inline"
                style="color: var(--text-secondary);"
              >
                loom<span class="font-semibold" style="color: var(--brand);">kin</span>
              </span>
            </.link>

            <div class="flex items-center gap-3">
              <%= if @user do %>
                <.link
                  navigate={~p"/users/settings"}
                  class="w-7 h-7 rounded-full flex items-center justify-center transition-all"
                  style="background: var(--surface-3); border: 1px solid var(--border-subtle);"
                >
                  <span class="text-[10px] font-bold" style="color: var(--text-muted);">
                    {((@user.username || @user.email || "?") |> String.first() || "?")
                    |> String.upcase()}
                  </span>
                </.link>
              <% else %>
                <.link
                  href={~p"/users/log-in"}
                  class="px-3 py-1 rounded-md text-xs transition-colors"
                  style="color: var(--text-muted);"
                >
                  Log in
                </.link>
                <.link
                  href={~p"/users/register"}
                  class="px-3 py-1 rounded-md text-xs font-medium text-white transition-colors"
                  style="background: var(--brand);"
                >
                  Sign up
                </.link>
              <% end %>
            </div>
          </div>
        </div>
      </nav>

      <%!-- Main content --%>
      <div class="relative z-10 max-w-5xl mx-auto px-5">
        <%= if @user do %>
          <.vault_dashboard user={@user} vaults={@vaults} />
        <% else %>
          <.signed_out_hero />
        <% end %>
      </div>
    </div>
    """
  end

  # ── Signed-out hero ──

  defp signed_out_hero(assigns) do
    ~H"""
    <div class="pt-32 pb-24">
      <%!-- Atmospheric glow behind the text --%>
      <div
        class="absolute top-20 left-1/2 -translate-x-1/2 w-[600px] h-[300px] rounded-full blur-[120px] opacity-20 pointer-events-none"
        style="background: radial-gradient(ellipse, var(--accent-mauve), transparent 70%);"
      />

      <div class="relative text-center">
        <p
          class="text-[11px] font-mono uppercase tracking-[0.3em] mb-8"
          style="color: var(--text-muted);"
        >
          agent orchestration platform
        </p>

        <%!-- Owl perched above the wordmark --%>
        <div class="mb-4">
          <svg
            width="56"
            height="56"
            viewBox="0 0 32 32"
            fill="none"
            class="mx-auto drop-shadow-[0_0_24px_rgba(180,160,232,0.2)]"
          >
            <%!-- Nestled body --%>
            <path
              d="M16 3C9.5 3 5.5 7.5 5.5 13.5c0 3.5 1.5 6.5 3.5 8.5C11 24 13 26 16 26s5-2 7-4c2-2 3.5-5 3.5-8.5C26.5 7.5 22.5 3 16 3z"
              fill="var(--surface-1)"
              stroke="var(--brand)"
              stroke-width="1"
            />
            <%!-- Ear tufts --%>
            <path
              d="M11 5.5L9.5 2.5M21 5.5l1.5-3"
              stroke="var(--brand)"
              stroke-width="1.2"
              stroke-linecap="round"
            />
            <%!-- Wings --%>
            <path
              d="M8 16c1.5 2 2.5 4.5 3 7M24 16c-1.5 2-2.5 4.5-3 7"
              stroke="var(--brand)"
              stroke-width="0.8"
              stroke-linecap="round"
              opacity="0.3"
            />
            <%!-- Chest feathers --%>
            <path
              d="M13 20c1-.6 2-.9 3-.9s2 .3 3 .9M13.5 22c.8-.4 1.6-.6 2.5-.6s1.7.2 2.5.6"
              stroke="var(--brand)"
              stroke-width="0.7"
              stroke-linecap="round"
              opacity="0.2"
            />
            <%!-- Eyes --%>
            <circle
              cx="12"
              cy="13"
              r="3.5"
              fill="var(--surface-0)"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
            />
            <circle cx="12.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
            <circle
              cx="20"
              cy="13"
              r="3.5"
              fill="var(--surface-0)"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
            />
            <circle cx="20.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
            <%!-- Beak --%>
            <path
              d="M15 17l1 1.5 1-1.5"
              stroke="var(--accent-peach)"
              stroke-width="1"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </div>

        <h1
          class="text-5xl md:text-6xl font-light tracking-tight mb-0"
          style="color: var(--text-primary);"
        >
          loom<span class="font-semibold" style="color: var(--brand);">kin</span>
        </h1>

        <%!-- Nest — woven branches under the wordmark --%>
        <div class="flex justify-center -mt-1 mb-6">
          <svg width="180" height="20" viewBox="0 0 180 20" fill="none" class="opacity-60">
            <%!-- Layered organic branch strokes --%>
            <path
              d="M20 12 C40 8, 60 14, 90 10 S140 6, 160 11"
              stroke="var(--accent-amber)"
              stroke-width="1.5"
              stroke-linecap="round"
              opacity="0.5"
            />
            <path
              d="M15 14 C45 10, 70 16, 95 12 S135 8, 165 13"
              stroke="var(--brand)"
              stroke-width="1"
              stroke-linecap="round"
              opacity="0.35"
            />
            <path
              d="M25 10 C50 15, 80 9, 100 13 S140 11, 155 9"
              stroke="var(--accent-peach)"
              stroke-width="1.2"
              stroke-linecap="round"
              opacity="0.3"
            />
            <%!-- A few small twig accents --%>
            <path
              d="M55 11 L52 8"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
              stroke-linecap="round"
              opacity="0.4"
            />
            <path
              d="M120 10 L123 7"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
              stroke-linecap="round"
              opacity="0.4"
            />
            <path
              d="M85 13 L82 10"
              stroke="var(--accent-peach)"
              stroke-width="0.7"
              stroke-linecap="round"
              opacity="0.3"
            />
          </svg>
        </div>

        <p
          class="text-sm max-w-sm mx-auto leading-relaxed"
          style="color: var(--text-secondary);"
        >
          AI agent teams that work alongside yours. <br />
          <span style="color: var(--text-muted);">Orchestrate, delegate, and build — together.</span>
        </p>
      </div>

      <%!-- Capability hints — quiet, not CTAs --%>
      <div class="flex items-center justify-center gap-8 mt-16">
        <div
          :for={
            {label, icon_path} <- [
              {"Knowledge Vaults",
               "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253"},
              {"Agent Teams",
               "M18 18.72a9.094 9.094 0 003.741-.479 3 3 0 00-4.682-2.72m.94 3.198l.001.031c0 .225-.012.447-.037.666A11.944 11.944 0 0112 21c-2.17 0-4.207-.576-5.963-1.584A6.062 6.062 0 016 18.719m12 0a5.971 5.971 0 00-.941-3.197m0 0A5.995 5.995 0 0012 12.75a5.995 5.995 0 00-5.058 2.772m0 0a3 3 0 00-4.681 2.72 8.986 8.986 0 003.74.477m.94-3.197a5.971 5.971 0 00-.94 3.197M15 6.75a3 3 0 11-6 0 3 3 0 016 0zm6 3a2.25 2.25 0 11-4.5 0 2.25 2.25 0 014.5 0zm-13.5 0a2.25 2.25 0 11-4.5 0 2.25 2.25 0 014.5 0z"},
              {"Decision Graphs",
               "M7.5 21L3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5"}
            ]
          }
          class="flex items-center gap-2"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-3.5 h-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1.5"
            style="color: var(--text-muted);"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d={icon_path} />
          </svg>
          <span class="text-xs" style="color: var(--text-muted);">{label}</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Vault dashboard (signed in) ──

  attr :user, :any, required: true
  attr :vaults, :list, required: true

  defp vault_dashboard(assigns) do
    ~H"""
    <div class="pt-12 pb-20">
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 class="text-xl font-semibold mb-1" style="color: var(--text-primary);">
            Your Vaults
          </h1>
          <p class="text-sm" style="color: var(--text-muted);">
            Knowledge bases managed by your teams
          </p>
        </div>
      </div>

      <%= if @vaults == [] do %>
        <div
          class="rounded-xl p-12 text-center border"
          style="background: var(--surface-1); border-color: var(--border-subtle);"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-10 h-10 mx-auto mb-4"
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
          <p class="text-sm mb-1" style="color: var(--text-secondary);">
            No vaults available yet
          </p>
          <p class="text-xs" style="color: var(--text-muted);">
            Vaults will appear here once your organization sets one up.
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <.vault_card :for={vault <- @vaults} vault={vault} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :vault, :map, required: true

  defp vault_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/vault/#{@vault.vault_id}"}
      class="group block rounded-xl p-5 border transition-all"
      style="background: var(--surface-1); border-color: var(--border-subtle);"
    >
      <div class="flex items-start gap-3 mb-3">
        <div
          class="w-9 h-9 rounded-lg flex items-center justify-center shrink-0"
          style="background: var(--brand-subtle);"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-4.5 h-4.5"
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
        <div class="min-w-0">
          <h3
            class="text-sm font-medium truncate group-hover:text-[var(--brand)]"
            style="color: var(--text-primary); transition: color var(--transition-fast);"
          >
            {@vault.name}
          </h3>
          <p
            :if={@vault.description}
            class="text-xs mt-0.5 line-clamp-2"
            style="color: var(--text-muted);"
          >
            {@vault.description}
          </p>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <span
          class="text-xs px-2 py-0.5 rounded"
          style="background: var(--surface-2); color: var(--text-muted);"
        >
          {@vault.storage_type}
        </span>
        <span
          class="text-xs ml-auto opacity-0 group-hover:opacity-100 transition-opacity"
          style="color: var(--text-brand);"
        >
          Open →
        </span>
      </div>
    </.link>
    """
  end

  # ── Data loading ──

  defp load_user_vaults(user) do
    import Ecto.Query

    # Get all orgs the user belongs to
    org_ids =
      Loomkin.Repo.all(
        from(m in Loomkin.Schemas.OrganizationMembership,
          where: m.user_id == ^user.id,
          select: m.organization_id
        )
      )

    # Get vaults for those orgs + unscoped vaults
    Loomkin.Repo.all(
      from(vc in Loomkin.Schemas.VaultConfig,
        where: vc.organization_id in ^org_ids or is_nil(vc.organization_id),
        order_by: [asc: vc.name]
      )
    )
  end
end
