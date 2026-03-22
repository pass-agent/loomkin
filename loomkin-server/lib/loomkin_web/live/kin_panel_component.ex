defmodule LoomkinWeb.KinPanelComponent do
  @moduledoc """
  Slide-over panel for managing kin agent configurations.

  Two modes:
    - :list — shows all kin agents with quick actions
    - :edit — create/edit form for a single kin agent
  """
  use LoomkinWeb, :live_component

  alias Loomkin.Kin
  alias Loomkin.Schemas.KinAgent
  alias Loomkin.Social

  @user_roles [:researcher, :coder, :reviewer, :tester]

  @presets [
    %{
      name: "researcher",
      display_name: "Researcher",
      role: :researcher,
      potency: 60,
      spawn_context: "When the task requires codebase exploration or architectural analysis"
    },
    %{
      name: "coder",
      display_name: "Coder",
      role: :coder,
      potency: 70,
      spawn_context: "When there are files to create or modify"
    },
    %{
      name: "reviewer",
      display_name: "Reviewer",
      role: :reviewer,
      potency: 40,
      spawn_context: "After code changes are complete and need review"
    },
    %{
      name: "tester",
      display_name: "Tester",
      role: :tester,
      potency: 40,
      spawn_context: "When implementation is done and tests need to be written or run"
    }
  ]

  def update(assigns, socket) do
    previously_loaded = Map.has_key?(socket.assigns, :kin_agents)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:panel_mode, fn -> :list end)
      |> assign_new(:form, fn -> nil end)
      |> assign_new(:editing_id, fn -> nil end)
      |> assign_new(:delete_confirm_id, fn -> nil end)
      |> assign_new(:multi_tenant, fn -> Application.get_env(:loomkin, :multi_tenant, false) end)

    # Only load from DB on first mount (panel open)
    socket = if previously_loaded, do: socket, else: load_kin_agents(socket)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex justify-end animate-fade-in"
      phx-window-keydown="kin_panel_keydown"
      phx-key="Escape"
      phx-target={@myself}
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/40"
        aria-hidden="true"
        phx-click="close_kin_panel"
        phx-target={@myself}
      />

      <%!-- Panel --%>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="kin-panel-title"
        class="relative w-full max-w-md bg-surface-0 border-l border-subtle flex flex-col animate-slide-in-right"
      >
        <%!-- Header --%>
        <div class="flex items-center gap-3 p-4 border-b border-subtle">
          <button
            :if={@panel_mode == :edit}
            phx-click="kin_back_to_list"
            phx-target={@myself}
            class="text-muted hover:text-primary p-1 rounded-md hover:bg-surface-2 transition-colors"
            data-tooltip="Back to list"
            aria-label="Back to list"
          >
            <svg class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M17 10a.75.75 0 01-.75.75H5.612l4.158 3.96a.75.75 0 11-1.04 1.08l-5.5-5.25a.75.75 0 010-1.08l5.5-5.25a.75.75 0 111.04 1.08L5.612 9.25H16.25A.75.75 0 0117 10z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <div class="flex-1">
            <h2 id="kin-panel-title" class="text-sm font-semibold text-primary">
              {if @panel_mode == :list,
                do: "Kin Management",
                else: if(@editing_id, do: "Edit Template", else: "New Template")}
            </h2>
            <p
              :if={@panel_mode == :list}
              class="text-[10px] mt-0.5"
              class="text-muted"
            >
              Templates any kin can spawn as needed
            </p>
          </div>
          <button
            :if={@panel_mode == :list}
            phx-click="kin_new"
            phx-target={@myself}
            class="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-colors"
            style="background: var(--brand-default); color: var(--text-on-brand);"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path d="M10.75 4.75a.75.75 0 00-1.5 0v4.5h-4.5a.75.75 0 000 1.5h4.5v4.5a.75.75 0 001.5 0v-4.5h4.5a.75.75 0 000-1.5h-4.5v-4.5z" />
            </svg>
            Template
          </button>
          <button
            phx-click="close_kin_panel"
            phx-target={@myself}
            class="text-muted hover:text-primary p-1 rounded-md hover:bg-surface-2 transition-colors"
            data-tooltip="Close panel"
            aria-label="Close panel"
          >
            <svg class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
              <path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />
            </svg>
          </button>
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-auto">
          <%= case @panel_mode do %>
            <% :list -> %>
              {render_list(assigns)}
            <% :edit -> %>
              {render_form(assigns)}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # --- List View ---

  defp render_list(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <%!-- Core Kin (always present) --%>
      <div>
        <p
          class="text-[10px] uppercase tracking-wider mb-2 font-medium"
          class="text-muted"
        >
          Core — always active
        </p>
        <div class="space-y-2">
          <div class="flex items-center gap-3 p-3 rounded-lg border border-subtle bg-surface-1">
            <div class="flex items-center justify-center w-7 h-7 rounded-full bg-violet-500/15 text-violet-400 text-xs font-bold flex-shrink-0">
              C
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium text-primary">Concierge</span>
                <span class="text-[10px] px-1.5 py-0.5 rounded font-medium bg-violet-500/15 text-violet-400">
                  core
                </span>
              </div>
              <p class="text-[10px] mt-0.5 text-muted">
                Your primary contact. Coordinates the team and spawns specialists as needed.
              </p>
            </div>
            <span
              :if={agent_active?("concierge", @active_agents)}
              class="w-2 h-2 rounded-full bg-green-400 flex-shrink-0"
              title="Active"
            />
          </div>
        </div>
      </div>

      <%!-- How it works callout --%>
      <div class="rounded-lg px-3 py-2.5 text-[11px] leading-relaxed bg-surface-1 text-muted border border-subtle">
        Kin spawn kin. The Concierge will create specialists automatically based on your
        tasks — or any kin can spawn others when it needs help. Templates below give them a
        head start.
      </div>

      <%!-- Separator --%>
      <div class="flex items-center gap-2">
        <div class="flex-1 h-px bg-border-subtle"></div>
        <span
          class="text-[10px] uppercase tracking-wider font-medium"
          class="text-muted"
        >
          Templates
        </span>
        <div class="flex-1 h-px bg-border-subtle"></div>
      </div>

      <%!-- Empty state for templates --%>
      <div
        :if={@kin_agents == []}
        class="rounded-lg border border-dashed py-8 text-center border-subtle bg-surface-1"
      >
        <svg
          class="w-7 h-7 mx-auto mb-2 opacity-30"
          class="text-muted"
          viewBox="0 0 20 20"
          fill="currentColor"
        >
          <path d="M7 8a3 3 0 100-6 3 3 0 000 6zM14.5 9a2.5 2.5 0 100-5 2.5 2.5 0 000 5zM1.615 16.428a1.224 1.224 0 01-.569-1.175 6.002 6.002 0 0111.908 0c.058.467-.172.92-.57 1.174A9.953 9.953 0 017 18a9.953 9.953 0 01-5.385-1.572zM14.5 16h-.106c.07-.297.088-.611.048-.933a7.47 7.47 0 00-1.588-3.755 4.502 4.502 0 015.874 2.636.818.818 0 01-.36.98A7.465 7.465 0 0114.5 16z" />
        </svg>
        <p class="text-xs font-medium text-secondary">No templates yet</p>
        <p class="text-[10px] mt-1 px-6 text-muted">
          Optional — kin will improvise without them, but templates let you predefine roles, models, and spawn rules.
        </p>
      </div>

      <div
        :for={kin <- @kin_agents}
        class={[
          "group relative flex items-center gap-3 p-3 rounded-lg border border-subtle transition-colors",
          if(kin.enabled,
            do: "bg-surface-1 hover:bg-surface-2",
            else: "opacity-50 bg-surface-1"
          )
        ]}
      >
        <%!-- Potency color bar --%>
        <div
          class="absolute left-0 top-2 bottom-2 w-1 rounded-r"
          style={"background: #{potency_color(kin.potency)};"}
        />

        <%!-- Info --%>
        <div class="flex-1 min-w-0 pl-2">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium truncate text-primary">
              {kin.display_name || kin.name}
            </span>
            <span class="text-[10px] px-1.5 py-0.5 rounded font-medium bg-brand-muted text-muted">
              {format_role(kin.role)}
            </span>
          </div>
          <div class="flex items-center gap-2 mt-0.5">
            <span
              class="text-[10px] font-medium"
              style={"color: #{potency_color(kin.potency)};"}
            >
              {potency_label(kin.potency)}
            </span>
            <span
              :if={kin.auto_spawn}
              class="text-[10px] px-1 py-0.5 rounded bg-emerald-500/15 text-emerald-400 font-medium"
            >
              auto-spawn
            </span>
            <span
              :if={kin.spawn_context}
              class="text-[10px] truncate max-w-[160px] text-muted"
              title={kin.spawn_context}
            >
              {kin.spawn_context}
            </span>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
          <%!-- Spawn button (if active team) --%>
          <button
            :if={@active_team_id && kin.enabled && !agent_active?(kin.name, @active_agents)}
            phx-click="kin_spawn"
            phx-value-id={kin.id}
            phx-target={@myself}
            data-tooltip="Spawn now"
            aria-label="Spawn now"
            class="text-emerald-400 hover:text-emerald-300 p-1 rounded-md hover:bg-surface-3 transition-colors"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <%!-- Active indicator --%>
          <span
            :if={agent_active?(kin.name, @active_agents)}
            class="w-2 h-2 rounded-full bg-green-400 flex-shrink-0"
            title="Active in session"
          />
          <%!-- Edit --%>
          <button
            phx-click="kin_edit"
            phx-value-id={kin.id}
            phx-target={@myself}
            data-tooltip="Edit template"
            aria-label="Edit template"
            class="text-muted hover:text-primary p-1 rounded-md hover:bg-surface-3 transition-colors"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
            </svg>
          </button>
          <%!-- Share as snippet (multi-tenant only) --%>
          <button
            :if={@multi_tenant}
            phx-click="share_kin"
            phx-value-id={kin.id}
            phx-target={@myself}
            data-tooltip="Share as snippet"
            aria-label="Share as snippet"
            class="text-muted hover:text-brand p-1 rounded-md hover:bg-surface-3 transition-colors"
          >
            <span class="hero-arrow-up-on-square-mini w-3.5 h-3.5" />
          </button>
          <%!-- Toggle enabled --%>
          <button
            phx-click="kin_toggle"
            phx-value-id={kin.id}
            phx-target={@myself}
            data-tooltip={if kin.enabled, do: "Disable template", else: "Enable template"}
            aria-label={if kin.enabled, do: "Disable template", else: "Enable template"}
            class={[
              "p-1 rounded-md hover:bg-surface-3 transition-colors",
              if(kin.enabled,
                do: "text-muted hover:text-amber-400",
                else: "text-muted hover:text-emerald-400"
              )
            ]}
          >
            <svg :if={kin.enabled} class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path d="M10 12.5a2.5 2.5 0 100-5 2.5 2.5 0 000 5z" />
              <path
                fill-rule="evenodd"
                d="M.664 10.59a1.651 1.651 0 010-1.186A10.004 10.004 0 0110 3c4.257 0 7.893 2.66 9.336 6.41.147.381.146.804 0 1.186A10.004 10.004 0 0110 17c-4.257 0-7.893-2.66-9.336-6.41zM14 10a4 4 0 11-8 0 4 4 0 018 0z"
                clip-rule="evenodd"
              />
            </svg>
            <svg :if={!kin.enabled} class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M3.28 2.22a.75.75 0 00-1.06 1.06l14.5 14.5a.75.75 0 101.06-1.06l-1.745-1.745a10.029 10.029 0 003.3-4.38 1.651 1.651 0 000-1.186A10.004 10.004 0 0010 3c-1.67 0-3.248.41-4.636 1.136L3.28 2.22zM7.905 6.845l1.18 1.18A2.5 2.5 0 0112.475 11.3l1.18 1.18A4 4 0 007.905 6.845z"
                clip-rule="evenodd"
              />
              <path d="M9.999 16.5c-1.67 0-3.248-.41-4.636-1.136L3.28 13.28a.75.75 0 00-1.06 1.06l1.745 1.745A10.029 10.029 0 00.664 10.59a1.651 1.651 0 010-1.186A10.004 10.004 0 019.999 3c.074 0 .148 0 .222.002L7.905 6.845a4 4 0 004.57 4.57l-2.316 2.316A10.07 10.07 0 019.999 16.5z" />
            </svg>
          </button>
          <%!-- Delete --%>
          <button
            :if={@delete_confirm_id != kin.id}
            phx-click="kin_delete_confirm"
            phx-value-id={kin.id}
            phx-target={@myself}
            data-tooltip="Delete template"
            aria-label="Delete template"
            class="text-muted hover:text-red-400 p-1 rounded-md hover:bg-surface-3 transition-colors"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M8.75 1A2.75 2.75 0 006 3.75v.443c-.795.077-1.584.176-2.365.298a.75.75 0 10.23 1.482l.149-.022 1.005 11.07A2.75 2.75 0 007.77 19.5h4.46a2.75 2.75 0 002.751-2.479l1.005-11.07.149.022a.75.75 0 00.23-1.482A41.03 41.03 0 0014 4.193V3.75A2.75 2.75 0 0011.25 1h-2.5zM10 4c.84 0 1.673.025 2.5.075V3.75c0-.69-.56-1.25-1.25-1.25h-2.5c-.69 0-1.25.56-1.25 1.25v.325C8.327 4.025 9.16 4 10 4zM8.58 7.72a.75.75 0 00-1.5.06l.3 7.5a.75.75 0 101.5-.06l-.3-7.5zm4.34.06a.75.75 0 10-1.5-.06l-.3 7.5a.75.75 0 101.5.06l.3-7.5z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <%!-- Delete confirm --%>
          <button
            :if={@delete_confirm_id == kin.id}
            phx-click="kin_delete"
            phx-value-id={kin.id}
            phx-target={@myself}
            class="text-[10px] font-medium px-2 py-1 rounded bg-red-500/20 text-red-400 hover:bg-red-500/30 transition-colors"
          >
            Confirm
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Edit/Create Form ---

  defp render_form(assigns) do
    ~H"""
    <div class="p-4">
      <%!-- Presets (only on create) --%>
      <div :if={!@editing_id} class="mb-4">
        <p class="text-[10px] uppercase tracking-wider mb-2 text-muted">
          Quick start
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={preset <- presets()}
            phx-click="kin_apply_preset"
            phx-value-preset={preset.name}
            phx-target={@myself}
            class="px-3 py-1.5 text-xs font-medium rounded-lg border border-subtle transition-colors hover:bg-surface-2 text-secondary"
          >
            {preset.display_name}
          </button>
        </div>
      </div>

      <.form
        for={@form}
        id="kin-form"
        phx-change="kin_validate"
        phx-submit="kin_save"
        phx-target={@myself}
        class="space-y-4"
      >
        <%!-- Name --%>
        <div>
          <label class="text-[10px] uppercase tracking-wider text-muted">
            Name <span class="text-red-400">*</span>
          </label>
          <input
            type="text"
            name={@form[:name].name}
            value={@form[:name].value}
            placeholder="e.g. code-reviewer"
            class="mt-1 w-full rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-violet-500/30 input-surface"
          />
          <p
            :for={{msg, opts} <- @form[:name].errors}
            class="text-red-400 text-[10px] mt-1"
          >
            {translate_error({msg, opts})}
          </p>
        </div>

        <%!-- Display Name --%>
        <div>
          <label class="text-[10px] uppercase tracking-wider text-muted">
            Display Name
          </label>
          <input
            type="text"
            name={@form[:display_name].name}
            value={@form[:display_name].value}
            placeholder="e.g. Code Reviewer"
            class="mt-1 w-full rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500/30 input-surface"
          />
        </div>

        <%!-- Role --%>
        <div>
          <label class="text-[10px] uppercase tracking-wider text-muted">
            Role <span class="text-red-400">*</span>
          </label>
          <select
            name={@form[:role].name}
            class="mt-1 w-full rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500/30 input-surface"
          >
            <option value="">Select a role...</option>
            <option
              :for={role <- user_roles()}
              value={role}
              selected={to_string(@form[:role].value) == to_string(role)}
            >
              {format_role(role)}
            </option>
          </select>
        </div>

        <%!-- Potency --%>
        <div>
          <label class="text-[10px] uppercase tracking-wider text-muted">
            Potency
          </label>
          <div class="mt-2">
            <%!-- Zone labels --%>
            <div class="flex text-[9px] font-medium mb-1 text-muted">
              <span class="flex-1 text-center" style="color: #71717a;">Dormant</span>
              <span class="flex-1 text-center" style="color: #60a5fa;">Available</span>
              <span class="flex-1 text-center" style="color: #fbbf24;">Suggested</span>
              <span class="flex-1 text-center" style="color: #34d399;">Recommended</span>
            </div>
            <%!-- Track with zones --%>
            <div class="relative h-2 rounded-full overflow-hidden flex">
              <div class="flex-1" style="background: #71717a40;"></div>
              <div class="flex-1" style="background: #60a5fa40;"></div>
              <div class="flex-1" style="background: #fbbf2440;"></div>
              <div class="flex-1" style="background: #34d39940;"></div>
            </div>
            <input
              type="range"
              name={@form[:potency].name}
              value={@form[:potency].value || 50}
              min="0"
              max="100"
              step="1"
              class="w-full -mt-2 accent-violet-500"
              style="opacity: 0.8;"
            />
            <div class="flex items-center justify-between mt-0.5">
              <span
                class="text-xs font-medium"
                style={"color: #{potency_color(@form[:potency].value || 50)};"}
              >
                {potency_label(@form[:potency].value || 50)}
              </span>
              <span class="text-xs font-mono text-muted">
                {@form[:potency].value || 50}
              </span>
            </div>
          </div>
        </div>

        <%!-- Spawn Context --%>
        <div>
          <label class="text-[10px] uppercase tracking-wider text-muted">
            Spawn Context
          </label>
          <textarea
            name={@form[:spawn_context].name}
            rows="3"
            placeholder="Describe WHEN this agent should be spawned, e.g. 'When the user asks about database migrations or schema changes'"
            class="mt-1 w-full rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500/30 resize-y input-surface"
          >{@form[:spawn_context].value}</textarea>
          <p class="text-[10px] mt-1 text-muted">
            Tells kin when to spawn this specialist
          </p>
        </div>

        <%!-- Auto-spawn toggle --%>
        <div class="flex items-center justify-between py-2">
          <div>
            <span class="text-xs font-medium text-primary">Auto-spawn</span>
            <p class="text-[10px] text-muted">
              Start automatically every session
            </p>
          </div>
          <label class="relative inline-flex items-center cursor-pointer">
            <input
              type="checkbox"
              name={@form[:auto_spawn].name}
              value="true"
              checked={@form[:auto_spawn].value == true || @form[:auto_spawn].value == "true"}
              class="sr-only peer"
            />
            <div class="w-9 h-5 bg-surface-3 rounded-full peer peer-checked:bg-emerald-500/60 transition-colors after:content-[''] after:absolute after:top-0.5 after:start-[2px] after:bg-white after:rounded-full after:h-4 after:w-4 after:transition-all peer-checked:after:translate-x-full">
            </div>
          </label>
        </div>

        <%!-- Advanced section --%>
        <details class="group">
          <summary class="flex items-center gap-2 cursor-pointer text-xs font-medium py-2 select-none text-muted">
            <svg
              class="w-3 h-3 transition-transform group-open:rotate-90"
              viewBox="0 0 20 20"
              fill="currentColor"
            >
              <path
                fill-rule="evenodd"
                d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
                clip-rule="evenodd"
              />
            </svg>
            Advanced
          </summary>
          <div class="space-y-4 pt-2">
            <%!-- Model Override --%>
            <div class="opacity-50">
              <label class="text-[10px] uppercase tracking-wider text-muted">
                Model Override
              </label>
              <input
                type="text"
                disabled
                placeholder="Coming soon"
                class="mt-1 w-full rounded-lg px-3 py-2 text-sm font-mono cursor-not-allowed input-surface text-muted"
              />
            </div>

            <%!-- System Prompt Extra --%>
            <div>
              <label class="text-[10px] uppercase tracking-wider text-muted">
                Extra System Prompt
              </label>
              <textarea
                name={@form[:system_prompt_extra].name}
                rows="3"
                placeholder="Additional instructions appended to the role's base prompt"
                class="mt-1 w-full rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500/30 resize-y input-surface"
              >{@form[:system_prompt_extra].value}</textarea>
            </div>

            <%!-- Budget Limit --%>
            <div>
              <label class="text-[10px] uppercase tracking-wider text-muted">
                Budget Limit (tokens)
              </label>
              <input
                type="number"
                name={@form[:budget_limit].name}
                value={@form[:budget_limit].value}
                placeholder="Blank = unlimited"
                min="0"
                class="mt-1 w-full rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-violet-500/30 input-surface"
              />
            </div>

            <%!-- Tags --%>
            <div>
              <label class="text-[10px] uppercase tracking-wider text-muted">
                Tags
              </label>
              <input
                type="text"
                name={@form[:tags].name}
                value={
                  if(is_list(@form[:tags].value),
                    do: Enum.join(@form[:tags].value, ", "),
                    else: @form[:tags].value
                  )
                }
                placeholder="Comma-separated, e.g. frontend, css"
                class="mt-1 w-full rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500/30 input-surface"
              />
            </div>
          </div>
        </details>

        <%!-- Submit --%>
        <div class="flex gap-2 justify-end pt-2">
          <button
            type="button"
            phx-click="kin_back_to_list"
            phx-target={@myself}
            class="px-4 py-2 text-xs font-medium rounded-xl transition-colors bg-surface-2 text-muted border border-subtle"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 text-xs font-medium rounded-xl transition-colors shadow-lg"
            style="background: var(--brand-default); color: var(--text-on-brand);"
          >
            {if @editing_id, do: "Save Changes", else: "Create Kin"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # --- Events ---

  def handle_event("kin_panel_keydown", %{"key" => "Escape"}, socket) do
    send(self(), :close_kin_panel)
    {:noreply, socket}
  end

  def handle_event("kin_panel_keydown", _, socket), do: {:noreply, socket}

  def handle_event("close_kin_panel", _params, socket) do
    send(self(), :close_kin_panel)
    {:noreply, socket}
  end

  def handle_event("kin_new", _params, socket) do
    form = KinAgent.changeset(%{}) |> to_form(as: "kin")
    {:noreply, assign(socket, panel_mode: :edit, form: form, editing_id: nil)}
  end

  def handle_event("kin_edit", %{"id" => id}, socket) do
    case Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        form =
          kin
          |> KinAgent.changeset(%{})
          |> to_form(as: "kin")

        {:noreply, assign(socket, panel_mode: :edit, form: form, editing_id: id)}
    end
  end

  def handle_event("kin_apply_preset", %{"preset" => name}, socket) do
    preset = Enum.find(presets(), &(&1.name == name)) || %{}

    attrs =
      preset
      |> Map.take([:name, :display_name, :role, :potency, :spawn_context])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    form =
      KinAgent.changeset(attrs)
      |> to_form(as: "kin")

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("kin_validate", %{"kin" => params}, socket) do
    params = normalize_params(params)

    changeset =
      if socket.assigns.editing_id do
        kin = Kin.get_kin(socket.assigns.editing_id)
        KinAgent.changeset(kin || %KinAgent{}, params)
      else
        KinAgent.changeset(params)
      end

    form = to_form(changeset, as: "kin", action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("kin_save", %{"kin" => params}, socket) do
    params = normalize_params(params)

    result =
      if socket.assigns.editing_id do
        kin = Kin.get_kin(socket.assigns.editing_id)
        Kin.update_kin(kin, params)
      else
        Kin.create_kin(params)
      end

    case result do
      {:ok, _kin} ->
        send(self(), :reload_kin_agents)

        {:noreply,
         socket
         |> assign(panel_mode: :list, form: nil, editing_id: nil)
         |> load_kin_agents()}

      {:error, changeset} ->
        form = to_form(changeset, as: "kin", action: :validate)
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("kin_toggle", %{"id" => id}, socket) do
    case Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        Kin.toggle_enabled(kin)
        send(self(), :reload_kin_agents)
        {:noreply, load_kin_agents(socket)}
    end
  end

  def handle_event("kin_delete_confirm", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_confirm_id: id)}
  end

  def handle_event("kin_delete", %{"id" => id}, socket) do
    case Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        Kin.delete_kin(kin)
        send(self(), :reload_kin_agents)
        {:noreply, socket |> assign(delete_confirm_id: nil) |> load_kin_agents()}
    end
  end

  def handle_event("kin_back_to_list", _params, socket) do
    {:noreply, assign(socket, panel_mode: :list, form: nil, editing_id: nil)}
  end

  def handle_event("kin_spawn", %{"id" => id}, socket) do
    case Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        send(self(), {:spawn_kin_agent, kin})
        {:noreply, socket}
    end
  end

  def handle_event("share_kin", %{"id" => id}, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user

    if is_nil(user) do
      {:noreply, socket}
    else
      do_share_kin(id, user, socket)
    end
  end

  defp do_share_kin(id, user, socket) do
    case Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        content = %{
          "role" => to_string(kin.role),
          "system_prompt_extra" => kin.system_prompt_extra || "",
          "potency" => kin.potency,
          "spawn_context" => kin.spawn_context || "",
          "auto_spawn" => kin.auto_spawn || false,
          "tool_overrides" => kin.tool_overrides || %{},
          "budget_limit" => kin.budget_limit
        }

        attrs = %{
          title: kin.display_name || kin.name,
          description: kin.spawn_context || "#{kin.role} agent configuration",
          type: :kin_agent,
          visibility: :private,
          content: content,
          tags: ["kin", to_string(kin.role)]
        }

        result = Social.create_snippet(user, attrs)
        send(self(), {:kin_shared, result})
        {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp load_kin_agents(socket) do
    kin_agents = Kin.list_all()
    assign(socket, kin_agents: kin_agents)
  end

  defp normalize_params(params) do
    params
    |> Map.update("auto_spawn", false, fn v -> v == "true" end)
    |> Map.update("tags", [], fn
      val when is_binary(val) ->
        val |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      val ->
        val
    end)
    |> Map.update("potency", 50, fn
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> 50
        end

      val ->
        val
    end)
  end

  defp agent_active?(name, active_agents) do
    Enum.any?(active_agents, fn a -> a.name == name end)
  end

  defp presets, do: @presets
  defp user_roles, do: @user_roles

  defp format_role(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp potency_label(potency) when is_integer(potency) do
    cond do
      potency >= 81 -> "RECOMMENDED"
      potency >= 51 -> "Suggested"
      potency >= 21 -> "Available"
      true -> "Dormant"
    end
  end

  defp potency_label(potency) when is_binary(potency) do
    case Integer.parse(potency) do
      {n, _} -> potency_label(n)
      :error -> "Available"
    end
  end

  defp potency_label(_), do: "Available"

  defp potency_color(potency) when is_integer(potency) do
    cond do
      potency >= 81 -> "#34d399"
      potency >= 51 -> "#fbbf24"
      potency >= 21 -> "#60a5fa"
      true -> "#71717a"
    end
  end

  defp potency_color(potency) when is_binary(potency) do
    case Integer.parse(potency) do
      {n, _} -> potency_color(n)
      :error -> "#60a5fa"
    end
  end

  defp potency_color(_), do: "#60a5fa"
end
