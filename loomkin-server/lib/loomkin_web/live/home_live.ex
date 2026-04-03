defmodule LoomkinWeb.HomeLive do
  @moduledoc """
  Landing page. Shows the Night Loom — owl's perch, CLI setup, and vault access.
  """
  use LoomkinWeb, :live_view

  def mount(_params, _session, socket) do
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

  def render(assigns) do
    ~H"""
    <div class="loom-home min-h-screen relative overflow-hidden" style="background: var(--surface-0);">
      <%!-- Woven thread background — diagonal lines that drift --%>
      <div class="loom-threads" aria-hidden="true">
        <svg class="absolute inset-0 w-full h-full" preserveAspectRatio="none">
          <line
            x1="0%"
            y1="20%"
            x2="100%"
            y2="35%"
            stroke="var(--brand)"
            stroke-width="0.5"
            opacity="0.06"
            class="loom-thread-1"
          />
          <line
            x1="0%"
            y1="45%"
            x2="100%"
            y2="25%"
            stroke="var(--accent-amber)"
            stroke-width="0.5"
            opacity="0.05"
            class="loom-thread-2"
          />
          <line
            x1="0%"
            y1="65%"
            x2="100%"
            y2="80%"
            stroke="var(--accent-cyan)"
            stroke-width="0.5"
            opacity="0.04"
            class="loom-thread-3"
          />
          <line
            x1="0%"
            y1="80%"
            x2="100%"
            y2="55%"
            stroke="var(--accent-peach)"
            stroke-width="0.5"
            opacity="0.04"
            class="loom-thread-4"
          />
          <line
            x1="0%"
            y1="10%"
            x2="100%"
            y2="60%"
            stroke="var(--accent-mauve)"
            stroke-width="0.3"
            opacity="0.03"
            class="loom-thread-5"
          />
          <line
            x1="0%"
            y1="90%"
            x2="100%"
            y2="40%"
            stroke="var(--accent-emerald)"
            stroke-width="0.3"
            opacity="0.03"
            class="loom-thread-6"
          />
        </svg>
      </div>

      <%!-- Top bar — minimal, just auth --%>
      <nav class="relative z-20 flex items-center justify-between px-6 py-4">
        <div class="w-20" />
        <div class="flex items-center gap-3">
          <%= if @user do %>
            <span class="text-xs font-mono" style="color: var(--text-muted);">
              {@user.username || @user.email}
            </span>
            <.link
              navigate={~p"/users/settings"}
              class="w-7 h-7 rounded-full flex items-center justify-center"
              style="background: var(--surface-2); border: 1px solid var(--border-subtle);"
            >
              <span class="text-[10px] font-bold" style="color: var(--text-muted);">
                {((@user.username || @user.email || "?") |> String.first() || "?")
                |> String.upcase()}
              </span>
            </.link>
          <% else %>
            <.link
              href={~p"/users/log-in"}
              class="px-3 py-1.5 rounded text-xs font-mono transition-colors"
              style="color: var(--text-muted); border: 1px solid var(--border-subtle);"
            >
              log in
            </.link>
            <.link
              href={~p"/users/register"}
              class="px-3 py-1.5 rounded text-xs font-mono transition-colors"
              style="color: var(--text-brand); border: 1px solid var(--brand); background: var(--brand-subtle);"
            >
              sign up
            </.link>
          <% end %>
        </div>
      </nav>

      <%!-- Main content --%>
      <div class="relative z-10">
        <%= if @user do %>
          <.the_perch user={@user} vaults={@vaults} />
        <% else %>
          <.the_night_loom />
        <% end %>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════
  # THE NIGHT LOOM — signed out hero
  # ═══════════════════════════════════════════════════════════════

  defp the_night_loom(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center min-h-[85vh] px-6">
      <%!-- The Owl — large, central, the thing you remember --%>
      <div class="loom-owl mb-8" style="animation: owlAppear 1.2s cubic-bezier(0.16, 1, 0.3, 1) both;">
        <svg width="120" height="120" viewBox="0 0 64 64" fill="none">
          <%!-- Ambient glow --%>
          <circle cx="32" cy="30" r="28" fill="var(--brand)" opacity="0.03" />

          <%!-- Body — plump, settled --%>
          <path
            d="M32 8C22 8 14 15 14 27c0 7 3 13 7 17 3 3 6 6 11 6s8-3 11-6c4-4 7-10 7-17C50 15 42 8 32 8z"
            fill="var(--surface-1)"
            stroke="var(--brand)"
            stroke-width="1"
          />

          <%!-- Ear tufts --%>
          <path
            d="M23 12L20 5M41 12l3-7"
            stroke="var(--brand)"
            stroke-width="1.2"
            stroke-linecap="round"
          />

          <%!-- Wing tuck lines --%>
          <path
            d="M18 32c2.5 4 4 9 5 14M46 32c-2.5 4-4 9-5 14"
            stroke="var(--brand)"
            stroke-width="0.6"
            stroke-linecap="round"
            opacity="0.25"
          />

          <%!-- Breast feather pattern — the craft detail --%>
          <path
            d="M26 40c2-1 4-1.5 6-1.5s4 .5 6 1.5"
            stroke="var(--accent-amber)"
            stroke-width="0.6"
            stroke-linecap="round"
            opacity="0.2"
          />
          <path
            d="M27 43c1.8-.8 3.2-1.2 5-1.2s3.2.4 5 1.2"
            stroke="var(--accent-peach)"
            stroke-width="0.5"
            stroke-linecap="round"
            opacity="0.15"
          />
          <path
            d="M28.5 46c1.2-.5 2.3-.7 3.5-.7s2.3.2 3.5.7"
            stroke="var(--brand)"
            stroke-width="0.5"
            stroke-linecap="round"
            opacity="0.12"
          />

          <%!-- Left eye --%>
          <circle
            cx="25"
            cy="26"
            r="6"
            fill="var(--surface-0)"
            stroke="var(--accent-amber)"
            stroke-width="0.8"
          />
          <circle
            cx="25"
            cy="26"
            r="4"
            fill="none"
            stroke="var(--accent-amber)"
            stroke-width="0.3"
            opacity="0.4"
          />
          <circle cx="25.5" cy="25.5" r="2.5" fill="var(--accent-amber)" />
          <circle cx="24.2" cy="24.5" r="0.8" fill="var(--surface-0)" opacity="0.7" />

          <%!-- Right eye --%>
          <circle
            cx="39"
            cy="26"
            r="6"
            fill="var(--surface-0)"
            stroke="var(--accent-amber)"
            stroke-width="0.8"
          />
          <circle
            cx="39"
            cy="26"
            r="4"
            fill="none"
            stroke="var(--accent-amber)"
            stroke-width="0.3"
            opacity="0.4"
          />
          <circle cx="39.5" cy="25.5" r="2.5" fill="var(--accent-amber)" />
          <circle cx="38.2" cy="24.5" r="0.8" fill="var(--surface-0)" opacity="0.7" />

          <%!-- Facial disc — the feather ring around eyes --%>
          <path
            d="M19 22c0-4 5-8 13-8s13 4 13 8"
            stroke="var(--brand)"
            stroke-width="0.5"
            stroke-linecap="round"
            opacity="0.2"
            fill="none"
          />

          <%!-- Beak --%>
          <path
            d="M30 33l2 3 2-3"
            stroke="var(--accent-peach)"
            stroke-width="1.2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />

          <%!-- Perch branch --%>
          <path
            d="M8 52 C16 50, 28 53, 32 51 S44 49, 56 52"
            stroke="var(--accent-amber)"
            stroke-width="1.5"
            stroke-linecap="round"
            opacity="0.4"
          />
          <path
            d="M12 54 C22 51, 38 55, 52 52"
            stroke="var(--accent-peach)"
            stroke-width="0.8"
            stroke-linecap="round"
            opacity="0.2"
          />
          <%!-- Small twigs off the branch --%>
          <path
            d="M20 52 L17 49"
            stroke="var(--accent-amber)"
            stroke-width="0.7"
            stroke-linecap="round"
            opacity="0.3"
          />
          <path
            d="M44 51 L47 48"
            stroke="var(--accent-amber)"
            stroke-width="0.7"
            stroke-linecap="round"
            opacity="0.3"
          />
          <path
            d="M36 53 L38 50"
            stroke="var(--accent-peach)"
            stroke-width="0.5"
            stroke-linecap="round"
            opacity="0.2"
          />
        </svg>
      </div>

      <%!-- The Name — not a heading, an identity --%>
      <div class="text-center" style="animation: fadeUp 0.8s 0.3s cubic-bezier(0.16, 1, 0.3, 1) both;">
        <h1
          class="text-6xl md:text-8xl font-extralight tracking-[-0.04em] leading-none"
          style="color: var(--text-primary);"
        >
          l<span class="font-light" style="color: var(--text-secondary);">oo</span>m<span
            class="font-semibold"
            style="color: var(--brand);"
          >kin</span>
        </h1>
      </div>

      <%!-- The Thread — what this is --%>
      <div
        class="mt-6 text-center"
        style="animation: fadeUp 0.8s 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;"
      >
        <p
          class="text-sm md:text-base font-light leading-relaxed"
          style="color: var(--text-secondary);"
        >
          autonomous agent teams that build while you sleep — or on the move
        </p>
      </div>

      <%!-- CLI setup --%>
      <div
        class="mt-16 max-w-md w-full"
        style="animation: fadeUp 0.8s 0.9s cubic-bezier(0.16, 1, 0.3, 1) both;"
      >
        <div
          class="rounded-xl p-6"
          style="background: var(--surface-1); border: 1px solid var(--border-subtle);"
        >
          <div class="flex items-center gap-2 mb-4">
            <div class="w-6 h-px" style="background: var(--brand); opacity: 0.4;" />
            <span
              class="font-mono text-[11px] tracking-wider"
              style="color: var(--text-muted);"
            >
              get started
            </span>
          </div>

          <p class="text-xs mb-4 leading-relaxed" style="color: var(--text-secondary);">
            loomkin runs in your terminal. install the cli, authenticate, and point it at your project.
          </p>

          <div class="space-y-2">
            <.cli_step number="1" command="bun add -g @loomkin/cli" />
            <.cli_step number="2" command="loomkin --login" />
            <.cli_step number="3" command="cd your-project && loomkin" />
          </div>
        </div>
      </div>

      <%!-- Auth links --%>
      <div
        class="mt-10 mb-8 flex items-center gap-4"
        style="animation: fadeUp 0.8s 1.2s cubic-bezier(0.16, 1, 0.3, 1) both;"
      >
        <.link href={~p"/users/register"} class="loom-btn loom-btn-outline">
          create account
        </.link>
        <.link
          href={~p"/users/log-in"}
          class="text-xs font-mono transition-colors"
          style="color: var(--text-muted);"
        >
          log in
        </.link>
      </div>
    </div>
    """
  end

  attr :number, :string, required: true
  attr :command, :string, required: true

  defp cli_step(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span
        class="flex-shrink-0 w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-mono"
        style="background: var(--surface-2); color: var(--text-muted); border: 1px solid var(--border-subtle);"
      >
        {@number}
      </span>
      <code
        class="text-[12px] font-mono px-2 py-1 rounded flex-1 select-all"
        style="background: var(--surface-0); color: var(--accent-amber); border: 1px solid var(--border-subtle);"
      >
        {@command}
      </code>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════
  # THE PERCH — signed in dashboard
  # ═══════════════════════════════════════════════════════════════

  attr :user, :any, required: true
  attr :vaults, :list, required: true

  defp the_perch(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-6 pt-8 pb-20">
      <%!-- Greeting — warm, personal --%>
      <div class="mb-12" style="animation: fadeUp 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;">
        <div class="flex items-center gap-3 mb-2">
          <div
            class="w-2 h-2 rounded-full"
            style="background: var(--accent-emerald); box-shadow: 0 0 8px var(--accent-emerald);"
          />
          <span class="text-xs font-mono" style="color: var(--text-muted);">
            {greeting_time()}
          </span>
        </div>
        <h1 class="text-2xl font-light" style="color: var(--text-primary);">
          Your vaults
        </h1>
      </div>

      <%!-- Vault cards --%>
      <%= if @vaults == [] do %>
        <div
          class="rounded-xl p-16 text-center"
          style="background: var(--surface-1); border: 1px dashed var(--border-default); animation: fadeUp 0.6s 0.15s cubic-bezier(0.16, 1, 0.3, 1) both;"
        >
          <%!-- Small sleeping owl --%>
          <svg width="40" height="40" viewBox="0 0 32 32" fill="none" class="mx-auto mb-4 opacity-40">
            <path
              d="M16 6C11 6 8 10 8 15c0 3 1 6 3 8 1.5 1.5 3 3 5 3s3.5-1.5 5-3c2-2 3-5 3-8 0-5-3-9-8-9z"
              fill="var(--surface-2)"
              stroke="var(--brand)"
              stroke-width="0.8"
            />
            <%!-- Closed eyes — sleeping --%>
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
          <p class="text-sm mb-1" style="color: var(--text-secondary);">
            No vaults yet
          </p>
          <p class="text-xs font-mono" style="color: var(--text-muted);">
            the owl rests until the first vault is woven
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.vault_card
            :for={{vault, idx} <- Enum.with_index(@vaults)}
            vault={vault}
            idx={idx}
          />
        </div>
      <% end %>
    </div>
    """
  end

  attr :vault, :map, required: true
  attr :idx, :integer, required: true

  defp vault_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/vault/#{@vault.vault_id}"}
      class="group relative block rounded-xl p-6 transition-all hover:translate-y-[-2px]"
      style={"background: var(--surface-1); border: 1px solid var(--border-subtle); animation: fadeUp 0.5s #{@idx * 0.1 + 0.15}s cubic-bezier(0.16, 1, 0.3, 1) both;"}
    >
      <%!-- Hover glow --%>
      <div
        class="absolute inset-0 rounded-xl opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none"
        style="box-shadow: var(--glow-brand);"
      />

      <div class="relative flex items-start justify-between">
        <div class="min-w-0 flex-1">
          <%!-- Thread accent line --%>
          <div class="flex items-center gap-3 mb-3">
            <div class="w-6 h-px" style="background: var(--brand); opacity: 0.4;" />
            <span
              class="text-[10px] font-mono uppercase tracking-widest"
              style="color: var(--text-muted);"
            >
              vault
            </span>
          </div>

          <h3
            class="text-lg font-medium mb-1 group-hover:text-[var(--brand)] transition-colors"
            style="color: var(--text-primary);"
          >
            {@vault.name}
          </h3>

          <p
            :if={@vault.description}
            class="text-xs leading-relaxed line-clamp-2 mb-4"
            style="color: var(--text-muted);"
          >
            {@vault.description}
          </p>
        </div>

        <%!-- Arrow — appears on hover --%>
        <div
          class="opacity-0 group-hover:opacity-100 transition-all group-hover:translate-x-1 mt-1"
          style="color: var(--brand);"
        >
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4.5 12h15m0 0l-6.75-6.75M19.5 12l-6.75 6.75"
            />
          </svg>
        </div>
      </div>
    </.link>
    """
  end

  # ── Helpers ──

  defp greeting_time do
    hour = DateTime.utc_now().hour

    cond do
      hour < 6 -> "the owl is awake"
      hour < 12 -> "good morning"
      hour < 18 -> "good afternoon"
      true -> "good evening"
    end
  end

  defp load_user_vaults(user) do
    Loomkin.Vault.list_vaults_for_user(user)
  end
end
