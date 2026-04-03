defmodule LoomkinWeb.MissionControlPanelComponent do
  @moduledoc """
  Left-panel LiveComponent for Mission Control mode.

  Renders the agent card grid with smart layout:
  - Concierge pinned at top (always visible, even on comms tab)
  - Active agents displayed as full cards with prominent visual treatment
  - Idle agents collapsed into compact single-line items (expandable)
  - Comms feed with noise-reduction filtering
  - Ghost cards for dormant kin

  All interactive events are forwarded to the parent WorkspaceLive via
  `send(self(), {:mission_control_event, event, params})`.

  Parent-provided assigns:
    - agent_cards               map of agent_name => card struct
    - concierge_card_names      list of agent names with concierge role
    - system_card_names         list of agent names with system/infrastructure roles
    - worker_card_names         list of agent names with worker roles
    - comms_event_count         integer
    - focused_agent             binary | nil
    - kin_agents                list of kin structs
    - cached_agents             list of cached agent structs
    - active_team_id            binary | nil
    - comms_stream              the @streams.comms_events value (may be nil in tests)
    - leader_approval_pending   map | nil — set when lead agent awaits sign-off
                                shape: %{gate_id, question, started_at, timeout_ms}
    - collab_health             integer (0-100) | nil — collaboration health score
  """

  use LoomkinWeb, :live_component

  # Statuses that indicate an agent is actively doing something
  @active_statuses [
    :working,
    :thinking,
    :approval_pending,
    :ask_user_pending,
    :waiting_permission,
    :suspended_healing,
    :recovering,
    :awaiting_synthesis
  ]

  # Content types that indicate active visual activity
  @active_content_types [:thinking, :tool_call, :streaming, :message]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:active_tab, fn -> :kin end)
      |> assign_new(:inspector_mode, fn -> :auto_follow end)
      |> assign_new(:idle_collapsed, fn -> true end)
      |> assign_new(:comms_filter, fn -> :all end)
      |> assign_new(:focus_modal_agent, fn -> nil end)
      |> assign_new(:focus_modal_tab, fn -> :activity end)

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("toggle_idle_agents", _params, socket) do
    {:noreply, assign(socket, idle_collapsed: !socket.assigns.idle_collapsed)}
  end

  def handle_event("set_comms_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, comms_filter: String.to_existing_atom(filter))}
  end

  def handle_event("open_focus_modal", %{"agent" => agent_name}, socket) do
    {:noreply, assign(socket, focus_modal_agent: agent_name, focus_modal_tab: :activity)}
  end

  def handle_event("close_focus_modal", _params, socket) do
    {:noreply, assign(socket, focus_modal_agent: nil)}
  end

  @valid_focus_tabs ~w(activity history tools stats)
  def handle_event("switch_focus_tab", %{"tab" => tab}, socket) when tab in @valid_focus_tabs do
    {:noreply, assign(socket, focus_modal_tab: String.to_existing_atom(tab))}
  end

  def handle_event(event, params, socket) do
    send(self(), {:mission_control_event, event, params})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    # Only show focused card in the left panel when the user explicitly pinned it
    # (inspector_mode == :pinned). Auto-follow updates the right inspector panel only,
    # so the left panel stays on whichever tab (kin/comms) the user chose.
    focused_card =
      if assigns.focused_agent && assigns.inspector_mode == :pinned &&
           assigns.active_tab == :kin do
        Map.get(assigns.agent_cards, assigns.focused_agent)
      end

    # Split workers into active and idle groups
    {active_workers, idle_workers} = split_workers(assigns.agent_cards, assigns.worker_card_names)

    # Focus modal card data
    focus_modal_card =
      if assigns.focus_modal_agent do
        Map.get(assigns.agent_cards, assigns.focus_modal_agent)
      end

    assigns =
      assigns
      |> assign(:focused_card, focused_card)
      |> assign(:active_workers, active_workers)
      |> assign(:idle_workers, idle_workers)
      |> assign(:focus_modal_card, focus_modal_card)

    ~H"""
    <div class="flex-1 flex flex-col min-w-0 min-h-0 bg-surface-0">
      <%!-- Focus Modal Overlay — tabbed deep-focus view --%>
      {render_focus_modal(assigns)}
      <%= if @focused_card do %>
        <%!-- Focused single-agent view --%>
        <div class="flex-1 flex flex-col min-h-0 p-3 overflow-hidden">
          <div class="flex items-center gap-2 mb-3 flex-shrink-0">
            <button
              phx-click="unfocus_agent"
              phx-target={@myself}
              class="text-xs text-muted hover:text-brand flex items-center gap-1 interactive"
            >
              <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
                <path
                  fill-rule="evenodd"
                  d="M9.707 16.707a1 1 0 01-1.414 0l-6-6a1 1 0 010-1.414l6-6a1 1 0 011.414 1.414L5.414 9H17a1 1 0 110 2H5.414l4.293 4.293a1 1 0 010 1.414z"
                  clip-rule="evenodd"
                />
              </svg>
              All agents
            </button>
          </div>
          <div class="flex-1 overflow-auto min-h-0">
            <.live_component
              module={LoomkinWeb.AgentCardComponent}
              id={"agent-card-#{@focused_card.name}"}
              card={@focused_card}
              focused={true}
              team_id={@active_team_id}
              model={@focused_card[:model]}
            />
          </div>
        </div>
      <% else %>
        <%!-- Leader approval banner — shown when lead agent awaits sign-off --%>
        <div
          :if={@leader_approval_pending}
          data-testid="leader-approval-banner"
          class="flex-shrink-0 mx-4 mt-3 px-4 py-3 rounded-xl border border-violet-500/50 bg-violet-950/40 backdrop-blur-sm flex flex-col gap-2.5"
        >
          <div class="flex items-start gap-3">
            <div class="w-2 h-2 rounded-full bg-violet-400 animate-pulse mt-1 flex-shrink-0"></div>
            <div class="flex-1 min-w-0">
              <p class="text-xs font-semibold text-violet-300 uppercase tracking-wider mb-1">
                Team leader awaiting your approval
              </p>
              <p class="text-sm text-gray-200">
                {@leader_approval_pending.question}
              </p>
            </div>
            <div
              class="text-xs tabular-nums text-violet-400 flex-shrink-0 mt-0.5"
              phx-hook="CountdownTimer"
              id={"leader-banner-timer-#{@leader_approval_pending.gate_id}"}
              data-deadline-at={
                @leader_approval_pending.started_at + @leader_approval_pending.timeout_ms
              }
            >
              ...
            </div>
          </div>
          <%!-- Approve / Deny buttons --%>
          <div class="flex items-center gap-1.5 ml-5">
            <button
              phx-click="approve_card_agent"
              phx-value-gate_id={@leader_approval_pending.gate_id}
              phx-value-agent={@leader_approval_pending[:agent_name] || "lead"}
              phx-value-context=""
              phx-disable-with="Approving..."
              class="px-3 py-1.5 text-[11px] font-medium rounded-md bg-violet-600/80 hover:bg-violet-600 text-white border border-violet-500/50 transition-colors cursor-pointer"
            >
              Approve
            </button>
            <button
              phx-click="deny_card_agent"
              phx-value-gate_id={@leader_approval_pending.gate_id}
              phx-value-agent={@leader_approval_pending[:agent_name] || "lead"}
              phx-value-reason=""
              phx-disable-with="Denying..."
              class="px-3 py-1.5 text-[11px] font-medium rounded-md bg-rose-900/40 hover:bg-rose-800/50 text-rose-300 border border-rose-700/30 transition-colors cursor-pointer"
            >
              Deny
            </button>
          </div>
        </div>

        <%!-- Concierge card moved to workspace_live.ex — pinned above composer for proximity --%>

        <%!-- Tab switcher: Kin / Comms --%>
        <div class="flex items-center gap-0.5 px-4 pt-2 pb-1.5 flex-shrink-0">
          <button
            phx-click="switch_tab"
            phx-value-tab="kin"
            phx-target={@myself}
            class={[
              "flex items-center gap-1.5 px-2 py-1 rounded text-[11px] font-medium transition-colors interactive",
              if(@active_tab == :kin,
                do:
                  "text-brand relative after:absolute after:bottom-0 after:inset-x-1 after:h-[2px] after:rounded-full after:bg-brand",
                else: "text-muted hover:text-secondary hover:bg-surface-2/50"
              )
            ]}
          >
            <.icon name="hero-user-group-mini" class="w-3.5 h-3.5" />
            <span>Kin</span>
            <span class="text-[10px] tabular-nums px-1.5 py-0.5 rounded-full bg-surface-2/60 text-muted">
              {length(@worker_card_names)}
            </span>
            <%!-- Active indicator dot --%>
            <span
              :if={@active_workers != []}
              class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"
            />
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="comms"
            phx-target={@myself}
            class={[
              "flex items-center gap-1.5 px-2 py-1 rounded text-[11px] font-medium transition-colors interactive",
              if(@active_tab == :comms,
                do:
                  "text-brand relative after:absolute after:bottom-0 after:inset-x-1 after:h-[2px] after:rounded-full after:bg-brand",
                else: "text-muted hover:text-secondary hover:bg-surface-2/50"
              )
            ]}
          >
            <.icon name="hero-signal-mini" class="w-3.5 h-3.5" />
            <span>Comms</span>
            <span
              :if={@comms_event_count > 0}
              class="text-[10px] tabular-nums px-1.5 py-0.5 rounded-full bg-surface-2/60 text-muted"
            >
              {@comms_event_count}
            </span>
          </button>
          <div class="flex-1" />
          {render_collab_health(assigns)}
          <%!-- Kill switch — dissolve active team --%>
          <button
            :if={@active_team_id && @worker_card_names != []}
            type="button"
            phx-click="dissolve_team"
            phx-target={@myself}
            class="flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] text-red-400/50 hover:text-red-300 hover:bg-red-500/10 transition-colors ml-1"
            title="Stop all agents and dissolve team"
          >
            <.icon name="hero-stop-mini" class="w-3 h-3" />
          </button>
        </div>

        <%= if @active_tab == :kin do %>
          <%!-- System agents — compact status with role identity --%>
          <div :if={system_card_names(assigns) != []} class="px-3 pb-2">
            <div
              :for={name <- system_card_names(assigns)}
              class="flex items-center gap-2 py-1.5 px-2.5 rounded-lg bg-surface-1/50 transition-colors hover:bg-surface-1/80"
            >
              <span class="text-xs flex-shrink-0">{system_role_icon(name, @agent_cards)}</span>
              <span class={[
                "w-1.5 h-1.5 rounded-full flex-shrink-0",
                system_status_dot(@agent_cards[name])
              ]} />
              <span class="text-[10px] font-medium text-muted truncate">
                {format_system_name(name)}
              </span>
              <span class="text-[9px] text-muted opacity-60 ml-auto flex-shrink-0">
                {system_agent_status_label(@agent_cards[name])}
              </span>
            </div>
          </div>

          <%!-- Team Agents Section --%>
          <div class="flex-1 p-4 pb-0 overflow-y-auto min-h-[120px]">
            <%!-- Waiting state: session exists but agents haven't spawned yet --%>
            <div
              :if={@concierge_card_names == [] && @worker_card_names == [] && @active_team_id}
              class="flex flex-col items-center justify-center h-full min-h-[320px] text-center px-8"
            >
              <%!-- Concierge avatar — warm, inviting with role icon --%>
              <div class="relative mb-6">
                <div
                  class="w-16 h-16 rounded-2xl flex items-center justify-center shadow-md"
                  style="background: linear-gradient(135deg, rgba(249, 226, 175, 0.08), rgba(249, 226, 175, 0.02)); border: 1px solid rgba(249, 226, 175, 0.12);"
                >
                  <span class="text-2xl">🌟</span>
                </div>
                <div class="absolute -bottom-1 -right-1 w-4 h-4 rounded-full bg-emerald-500/80 flex items-center justify-center">
                  <div class="w-2 h-2 rounded-full bg-emerald-300 animate-pulse" />
                </div>
              </div>

              <h3 class="text-base font-semibold text-primary mb-1">
                Your concierge is ready
              </h3>
              <p class="text-sm text-muted max-w-[280px] leading-relaxed mb-8">
                Send a message below and your kin team will assemble to help.
              </p>

              <%!-- What happens next — warm hints --%>
              <div class="flex flex-col gap-3 w-full max-w-[300px]">
                <div class="flex items-center gap-3 text-left">
                  <div class="w-8 h-8 rounded-lg bg-surface-2 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-chat-bubble-left-right-mini" class="w-4 h-4 text-brand/60" />
                  </div>
                  <div>
                    <div class="text-xs font-medium text-secondary">Describe your task</div>
                    <div class="text-[11px] text-muted">The concierge will plan the approach</div>
                  </div>
                </div>
                <div class="flex items-center gap-3 text-left">
                  <div class="w-8 h-8 rounded-lg bg-surface-2 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-user-group-mini" class="w-4 h-4 text-brand/60" />
                  </div>
                  <div>
                    <div class="text-xs font-medium text-secondary">Specialists spawn</div>
                    <div class="text-[11px] text-muted">Agents appear here as they join</div>
                  </div>
                </div>
                <div class="flex items-center gap-3 text-left">
                  <div class="w-8 h-8 rounded-lg bg-surface-2 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-eye-mini" class="w-4 h-4 text-brand/60" />
                  </div>
                  <div>
                    <div class="text-xs font-medium text-secondary">Watch them work</div>
                    <div class="text-[11px] text-muted">See thinking, tools, and comms live</div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- No session state --%>
            <div
              :if={@concierge_card_names == [] && @worker_card_names == [] && !@active_team_id}
              class="flex flex-col items-center justify-center h-full min-h-[200px] text-center px-8"
            >
              <div class="w-12 h-12 rounded-xl bg-surface-2 flex items-center justify-center mb-4">
                <.icon name="hero-sparkles-mini" class="w-6 h-6 text-muted" />
              </div>
              <div class="text-sm font-medium text-secondary mb-1">No session yet</div>
              <div class="text-xs text-muted">
                Start a session to meet your kin
              </div>
            </div>

            <%!-- Ghost cards for dormant kin (not yet spawned) --%>
            {render_ghost_cards(assigns)}

            <%!-- Active agents — full cards with prominent display --%>
            <%= if @active_workers != [] do %>
              <div class="mb-2">
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-emerald-400/80">
                    Active
                  </span>
                  <span class="text-[10px] tabular-nums text-emerald-400/50">
                    {length(@active_workers)}
                  </span>
                  <div class="flex-1 h-px bg-emerald-500/10" />
                </div>
                <div class={[
                  "agent-card-grid grid gap-3",
                  card_grid_cols(length(@active_workers)),
                  "grid-alive"
                ]}>
                  <div :for={name <- @active_workers} class="relative group/card">
                    <.live_component
                      module={LoomkinWeb.AgentCardComponent}
                      id={"agent-card-#{name}"}
                      card={@agent_cards[name]}
                      focused={false}
                      team_id={@active_team_id}
                      model={@agent_cards[name][:model]}
                    />
                    <%!-- Expand button overlay — opens tabbed focus modal --%>
                    <button
                      phx-click="open_focus_modal"
                      phx-value-agent={name}
                      phx-target={@myself}
                      class="absolute top-2 right-2 z-10 p-1 rounded-md bg-surface-0/80 backdrop-blur-sm opacity-0 group-hover/card:opacity-70 hover:!opacity-100 transition-opacity"
                      aria-label={"Expand #{name}"}
                      title="Deep focus view"
                    >
                      <.icon name="hero-arrows-pointing-out-mini" class="w-3.5 h-3.5 text-muted" />
                    </button>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Idle agents — collapsible compact list --%>
            <%= if @idle_workers != [] do %>
              <div class="idle-agents-section mt-2">
                <button
                  phx-click="toggle_idle_agents"
                  phx-target={@myself}
                  class="group flex items-center gap-2 w-full mb-1.5 cursor-pointer"
                >
                  <svg
                    class={[
                      "w-3 h-3 text-muted/60 transition-transform duration-200",
                      !@idle_collapsed && "rotate-90"
                    ]}
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path
                      fill-rule="evenodd"
                      d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
                      clip-rule="evenodd"
                    />
                  </svg>
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-muted/60 group-hover:text-muted transition-colors">
                    Idle
                  </span>
                  <span class="text-[10px] tabular-nums text-muted/40">
                    {length(@idle_workers)}
                  </span>
                  <div class="flex-1 h-px bg-surface-3/50" />
                </button>

                <%= if !@idle_collapsed do %>
                  <div class="idle-agents-list space-y-1 animate-fade-in">
                    <div
                      :for={name <- @idle_workers}
                      class="idle-agent-row group w-full flex items-center gap-2.5 px-3 py-2 rounded-lg transition-all duration-150 hover:bg-surface-2/80"
                    >
                      <button
                        phx-click="focus_card_agent"
                        phx-value-agent={name}
                        class="flex items-center gap-2.5 flex-1 min-w-0 cursor-pointer"
                      >
                        <%!-- Role icon mini-avatar --%>
                        <span
                          class="idle-role-avatar"
                          style={"background: #{agent_role_accent(name, @agent_cards)}10; border: 1px solid #{agent_role_accent(name, @agent_cards)}12;"}
                        >
                          {agent_role_icon(name, @agent_cards)}
                        </span>
                        <%!-- Name --%>
                        <span
                          class="text-xs font-medium truncate text-secondary group-hover:text-primary transition-colors"
                          style={"color: #{LoomkinWeb.AgentColors.agent_color(name)}80;"}
                        >
                          {name}
                        </span>
                        <%!-- Role badge --%>
                        <span
                          :if={
                            @agent_cards[name] && !role_matches_name?(@agent_cards[name].role, name)
                          }
                          class="text-[9px] font-mono text-muted/40 truncate"
                        >
                          {format_agent_role(@agent_cards[name].role)}
                        </span>
                        <%!-- Task snippet --%>
                        <span
                          :if={@agent_cards[name] && @agent_cards[name].current_task}
                          class="text-[9px] text-muted/30 truncate max-w-[120px] ml-auto"
                        >
                          {@agent_cards[name].current_task}
                        </span>
                      </button>
                      <%!-- Expand button --%>
                      <button
                        phx-click="open_focus_modal"
                        phx-value-agent={name}
                        phx-target={@myself}
                        class="opacity-0 group-hover:opacity-60 hover:!opacity-100 transition-opacity flex-shrink-0 p-1 rounded"
                        title="Deep focus view"
                      >
                        <.icon name="hero-arrows-pointing-out-mini" class="w-3 h-3 text-muted" />
                      </button>
                      <%!-- Reply button on hover --%>
                      <span class="opacity-0 group-hover:opacity-60 transition-opacity flex-shrink-0">
                        <.icon name="hero-chat-bubble-left-mini" class="w-3 h-3 text-muted" />
                      </span>
                    </div>
                  </div>
                <% else %>
                  <%!-- Collapsed summary: role-tinted dots for each idle agent --%>
                  <div class="flex items-center gap-1.5 px-3 py-1">
                    <span
                      :for={name <- @idle_workers}
                      class="w-2.5 h-2.5 rounded-md cursor-pointer transition-all duration-150 hover:scale-150"
                      style={"background: #{agent_role_accent(name, @agent_cards)}25;"}
                      phx-click="focus_card_agent"
                      phx-value-agent={name}
                      title={name}
                    />
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- All workers in a grid when none are active (backwards compat) --%>
            <%= if @active_workers == [] && @idle_workers == [] && @worker_card_names != [] do %>
              <div class={[
                "agent-card-grid grid gap-3",
                card_grid_cols(length(@worker_card_names)),
                any_agents_active?(@agent_cards, @worker_card_names) && "grid-alive"
              ]}>
                <.live_component
                  :for={name <- @worker_card_names}
                  module={LoomkinWeb.AgentCardComponent}
                  id={"agent-card-#{name}"}
                  card={@agent_cards[name]}
                  focused={false}
                  team_id={@active_team_id}
                  model={@agent_cards[name][:model]}
                />
              </div>
            <% end %>
          </div>
        <% else %>
          <%!-- Comms Feed (full height when active tab) --%>
          <%= if @comms_stream do %>
            <%!-- Comms filter strip --%>
            <div class="flex items-center gap-1 px-4 py-1.5 flex-shrink-0">
              <button
                :for={
                  {label, value} <- [
                    {"All", :all},
                    {"Important", :important},
                    {"Tasks", :tasks},
                    {"Errors", :errors}
                  ]
                }
                phx-click="set_comms_filter"
                phx-value-filter={value}
                phx-target={@myself}
                class={[
                  "px-2 py-0.5 rounded text-[10px] font-medium transition-colors",
                  if(@comms_filter == value,
                    do: "bg-brand-subtle text-brand",
                    else: "text-muted/50 hover:text-muted hover:bg-surface-2/50"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <div class="flex-1 overflow-auto min-h-[200px]">
              <LoomkinWeb.AgentCommsComponent.comms_feed
                stream={@comms_stream}
                event_count={@comms_event_count}
                id="agent-comms"
                root_team_id={@active_team_id}
                comms_filter={@comms_filter}
              />
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Split worker names into active and idle based on their card state
  defp split_workers(agent_cards, worker_card_names) do
    Enum.split_with(worker_card_names, fn name ->
      card = agent_cards[name]
      card && (card.status in @active_statuses || card.content_type in @active_content_types)
    end)
  end

  defp render_ghost_cards(assigns) do
    active_names = Enum.map(assigns.cached_agents, & &1.name)

    dormant_kin =
      assigns.kin_agents
      |> Enum.filter(fn k -> k.enabled && k.name not in active_names end)

    assigns = assign(assigns, dormant_kin: dormant_kin)

    ~H"""
    <%= if @dormant_kin != [] do %>
      <div class="flex flex-wrap gap-2 mt-2">
        <button
          :for={kin <- @dormant_kin}
          phx-click="spawn_dormant_kin"
          phx-value-id={kin.id}
          phx-target={@myself}
          class="group flex items-center gap-2.5 px-3.5 py-2.5 rounded-lg border border-dashed border-subtle/50 transition-all duration-200 hover:border-solid hover:border-subtle hover:bg-surface-2/60"
          aria-label={"Spawn #{kin.display_name || kin.name}"}
        >
          <span
            class="w-1.5 h-1.5 rounded-full opacity-50"
            style={"background: #{kin_potency_color(kin.potency)};"}
          />
          <span class="text-xs font-medium opacity-60 group-hover:opacity-100 transition-opacity text-secondary">
            {kin.display_name || kin.name}
          </span>
          <span class="text-[9px] px-1 py-0.5 rounded font-medium opacity-40 bg-brand-muted text-muted">
            {format_agent_role(kin.role)}
          </span>
          <svg
            class="w-3 h-3 opacity-0 group-hover:opacity-60 transition-opacity text-muted"
            viewBox="0 0 20 20"
            fill="currentColor"
            aria-hidden="true"
          >
            <path
              fill-rule="evenodd"
              d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
      </div>
    <% else %>
      <div
        :if={@worker_card_names == []}
        class="mt-3 py-8 text-center"
      >
        <div class="text-xs text-muted/60">Specialists will appear here as they join</div>
      </div>
    <% end %>
    """
  end

  defp render_collab_health(assigns) do
    ~H"""
    <div
      :if={@collab_health}
      data-testid="collab-health-indicator"
      class="flex items-center gap-1.5"
      title={"Collaboration Health: #{@collab_health}/100"}
    >
      <div class="w-16 h-1.5 rounded-full bg-surface-2 overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-500",
            health_color_class(@collab_health)
          ]}
          style={"width: #{@collab_health}%"}
        />
      </div>
      <span class={[
        "text-[10px] tabular-nums font-medium",
        health_text_class(@collab_health)
      ]}>
        {@collab_health}
      </span>
    </div>
    """
  end

  defp health_color_class(score) when score >= 70, do: "bg-emerald-500"
  defp health_color_class(score) when score >= 40, do: "bg-amber-400"
  defp health_color_class(_score), do: "bg-red-500"

  defp health_text_class(score) when score >= 70, do: "text-emerald-400"
  defp health_text_class(score) when score >= 40, do: "text-amber-400"
  defp health_text_class(_score), do: "text-red-400"

  defp card_grid_cols(count) when count == 1, do: "grid-cols-1"
  defp card_grid_cols(count) when count == 2, do: "grid-cols-2"
  defp card_grid_cols(_), do: "grid-cols-2 lg:grid-cols-3"

  defp any_agents_active?(agent_cards, card_names) do
    Enum.any?(card_names, fn name ->
      card = agent_cards[name]
      card && card.content_type in [:thinking, :tool_call, :streaming]
    end)
  end

  defp role_matches_name?(role, name) when is_atom(role) do
    to_string(role) == name
  end

  defp role_matches_name?(role, name) when is_binary(role), do: role == name
  defp role_matches_name?(_, _), do: true

  defp kin_potency_color(potency) when is_integer(potency) do
    cond do
      potency >= 81 -> "#34d399"
      potency >= 51 -> "#fbbf24"
      potency >= 21 -> "#60a5fa"
      true -> "#71717a"
    end
  end

  defp kin_potency_color(_), do: "#60a5fa"

  defp format_agent_role(role) when is_atom(role) or is_binary(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_agent_role(_), do: "-"

  defp system_card_names(assigns), do: assigns[:system_card_names] || []

  defp system_status_dot(nil), do: "bg-zinc-500"

  defp system_status_dot(card) do
    case card.status do
      s when s in [:complete, :idle] -> "bg-emerald-400"
      s when s in [:working, :thinking] -> "bg-amber-400 animate-pulse"
      :error -> "bg-red-400"
      _ -> "bg-zinc-500"
    end
  end

  defp system_agent_status_label(nil), do: "starting..."

  defp system_agent_status_label(card) do
    case card.status do
      s when s in [:working, :thinking] -> "scanning..."
      s when s in [:complete, :idle] -> "scan complete"
      :error -> "scan failed"
      _ -> "initializing..."
    end
  end

  defp format_system_name(name) when is_binary(name) do
    name |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_system_name(name), do: to_string(name)

  @system_role_icons %{
    "lead" => "👑",
    "concierge" => "🌟",
    "researcher" => "🔬",
    "coder" => "⚡",
    "reviewer" => "🔍",
    "tester" => "🧪"
  }

  @role_accents %{
    "lead" => "#cba6f7",
    "concierge" => "#f9e2af",
    "researcher" => "#89dceb",
    "coder" => "#a6e3a1",
    "reviewer" => "#fab387",
    "tester" => "#f38ba8"
  }

  @default_accent "#a1a1aa"

  # System agent role icon lookup — maps agent name to its card's role icon
  defp system_role_icon(name, agent_cards) do
    case agent_cards[name] do
      nil -> "◆"
      %{role: role} -> role_to_icon(role)
      _ -> "◆"
    end
  end

  # Agent role icon lookup — for idle agents list
  defp agent_role_icon(name, agent_cards) do
    case agent_cards[name] do
      nil -> "◆"
      %{role: role} -> role_to_icon(role)
      _ -> "◆"
    end
  end

  # Agent role accent color lookup — for idle agent styling
  defp agent_role_accent(name, agent_cards) do
    case agent_cards[name] do
      nil -> @default_accent
      %{role: role} -> role_to_accent(role)
      _ -> @default_accent
    end
  end

  defp role_to_icon(role) when is_atom(role) or is_binary(role) do
    base =
      role |> to_string() |> String.downcase() |> String.split([" ", "-", "_"]) |> List.first()

    Map.get(@system_role_icons, base, "◆")
  end

  defp role_to_icon(_), do: "◆"

  defp role_to_accent(role) when is_atom(role) or is_binary(role) do
    base =
      role |> to_string() |> String.downcase() |> String.split([" ", "-", "_"]) |> List.first()

    Map.get(@role_accents, base, @default_accent)
  end

  defp role_to_accent(_), do: @default_accent

  # ── Focus Modal: tabbed agent deep-dive ──

  defp render_focus_modal(assigns) do
    ~H"""
    <div
      :if={@focus_modal_agent && @focus_modal_card}
      id="focus-modal-overlay"
      class="fixed inset-0 z-50 flex items-center justify-center focus-modal-overlay"
      phx-window-keydown="close_focus_modal"
      phx-key="Escape"
      phx-target={@myself}
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/60 backdrop-blur-sm"
        phx-click="close_focus_modal"
        phx-target={@myself}
        aria-hidden="true"
      />

      <%!-- Modal content --%>
      <div
        class="relative z-10 w-full max-w-2xl max-h-[80vh] mx-4 flex flex-col rounded-2xl overflow-hidden focus-modal-container"
        style={"border: 1px solid #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}20; box-shadow: 0 0 40px #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}10;"}
      >
        <%!-- Header: Agent identity + state + close --%>
        <div
          class="flex items-center gap-3 px-5 py-4 border-b border-border-subtle flex-shrink-0"
          style={"background: linear-gradient(135deg, #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}08, transparent);"}
        >
          <%!-- Agent avatar --%>
          <div
            class="w-10 h-10 rounded-xl flex items-center justify-center text-base font-bold relative flex-shrink-0"
            style={"background: #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}18; color: #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)};"}
          >
            {String.first(@focus_modal_agent) |> String.upcase()}
            <span class={[
              "absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full ring-2 ring-surface-1",
              modal_status_dot(@focus_modal_card.status)
            ]} />
          </div>

          <%!-- Name + role + status --%>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <span
                class="text-base font-semibold truncate"
                style={"color: #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)};"}
              >
                {@focus_modal_agent}
              </span>
              <span class={[
                "text-[10px] font-medium px-2 py-0.5 rounded-full",
                modal_status_pill(@focus_modal_card.status)
              ]}>
                {modal_status_label(@focus_modal_card.status)}
              </span>
            </div>
            <div class="flex items-center gap-2 mt-0.5">
              <span
                :if={!role_matches_name?(@focus_modal_card.role, @focus_modal_agent)}
                class="text-[11px] text-muted font-mono"
              >
                {format_agent_role(@focus_modal_card.role)}
              </span>
              <span
                :if={@focus_modal_card.current_task}
                class="text-[11px] text-muted truncate"
              >
                📋 {@focus_modal_card.current_task}
              </span>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div class="flex items-center gap-1 flex-shrink-0">
            <button
              phx-click="reply_to_card_agent"
              phx-value-agent={@focus_modal_agent}
              phx-value-team-id={@active_team_id}
              class="p-2 rounded-lg hover:bg-surface-2 text-muted hover:text-brand transition-colors"
              title="Reply to agent"
            >
              <.icon name="hero-chat-bubble-left-mini" class="w-4 h-4" />
            </button>
            <button
              :if={@focus_modal_card.status == :working}
              phx-click="pause_card_agent"
              phx-value-agent={@focus_modal_agent}
              phx-value-team-id={@active_team_id}
              class="p-2 rounded-lg hover:bg-surface-2 text-muted hover:text-amber-400 transition-colors"
              title="Pause agent"
            >
              <.icon name="hero-pause-circle-mini" class="w-4 h-4" />
            </button>
            <button
              phx-click="close_focus_modal"
              phx-target={@myself}
              class="p-2 rounded-lg hover:bg-surface-2 text-muted hover:text-primary transition-colors"
              title="Close"
            >
              <.icon name="hero-x-mark-mini" class="w-4 h-4" />
            </button>
          </div>
        </div>

        <%!-- Tab bar --%>
        <div class="flex items-center gap-0.5 px-5 py-1.5 border-b border-border-subtle bg-surface-0/80 flex-shrink-0">
          <button
            :for={
              {label, icon, tab_id} <- [
                {"Activity", "hero-bolt-mini", "activity"},
                {"History", "hero-clock-mini", "history"},
                {"Tools", "hero-wrench-screwdriver-mini", "tools"},
                {"Stats", "hero-chart-bar-mini", "stats"}
              ]
            }
            phx-click="switch_focus_tab"
            phx-value-tab={tab_id}
            phx-target={@myself}
            class={[
              "flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-colors",
              if(to_string(@focus_modal_tab) == tab_id,
                do: "bg-brand-subtle text-brand",
                else: "text-muted hover:text-secondary hover:bg-surface-2/50"
              )
            ]}
          >
            <.icon name={icon} class="w-3.5 h-3.5" />
            <span>{label}</span>
          </button>
        </div>

        <%!-- Tab content --%>
        <div class="flex-1 overflow-y-auto min-h-0 focus-modal-content">
          {render_focus_tab(@focus_modal_tab, assigns)}
        </div>
      </div>
    </div>
    """
  end

  # ── Focus modal tab renderers ──

  defp render_focus_tab(:activity, assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <%!-- Current thinking / streaming content --%>
      <%= if @focus_modal_card.content_type in [:thinking, :streaming] && @focus_modal_card.latest_content do %>
        <div class="space-y-1">
          <div class="flex items-center gap-1.5">
            <span class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-pulse" />
            <span class="text-[10px] font-semibold uppercase tracking-wider text-violet-400">
              Thinking now
            </span>
          </div>
          <div
            class="text-sm leading-relaxed text-secondary agent-card-content rounded-lg px-3 py-2"
            style={"background: #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}06; border-left: 2px solid #{LoomkinWeb.AgentColors.agent_color(@focus_modal_agent)}30;"}
          >
            {render_modal_markdown(@focus_modal_card.latest_content)}
          </div>
        </div>
      <% end %>

      <%!-- Last response --%>
      <%= if @focus_modal_card[:last_response] do %>
        <div class="space-y-1">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-emerald-400/70">
            Last response
          </span>
          <div class="text-sm leading-relaxed text-secondary agent-card-content rounded-lg px-3 py-2 bg-surface-1">
            {render_modal_markdown(@focus_modal_card[:last_response])}
          </div>
        </div>
      <% end %>

      <%!-- Last tool call --%>
      <div :if={@focus_modal_card.last_tool} class="space-y-1">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted/60">
          Last tool
        </span>
        <div class="flex items-center gap-2 px-3 py-2 rounded-lg bg-surface-1 font-mono">
          <span class="text-xs">{modal_tool_icon(@focus_modal_card.last_tool)}</span>
          <span class="text-xs text-secondary">{modal_tool_label(@focus_modal_card.last_tool)}</span>
        </div>
      </div>

      <%!-- Status summary --%>
      <div class="space-y-1">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted/60">
          Status summary
        </span>
        <div class="grid grid-cols-2 gap-2">
          <div class="px-3 py-2 rounded-lg bg-surface-1">
            <div class="text-[10px] text-muted/60 mb-0.5">Status</div>
            <div class={["text-xs font-medium", modal_status_text(@focus_modal_card.status)]}>
              {modal_status_label(@focus_modal_card.status)}
            </div>
          </div>
          <div class="px-3 py-2 rounded-lg bg-surface-1">
            <div class="text-[10px] text-muted/60 mb-0.5">Thoughts</div>
            <div class="text-xs font-medium text-secondary">
              {length(Map.get(@focus_modal_card, :thought_history, []))}
            </div>
          </div>
          <div class="px-3 py-2 rounded-lg bg-surface-1">
            <div class="text-[10px] text-muted/60 mb-0.5">Budget used</div>
            <div class="text-xs font-medium text-secondary font-mono">
              {modal_format_tokens(Map.get(@focus_modal_card, :budget_used, 0))}
            </div>
          </div>
          <div class="px-3 py-2 rounded-lg bg-surface-1">
            <div class="text-[10px] text-muted/60 mb-0.5">Content</div>
            <div class="text-xs font-medium text-secondary">
              {modal_content_type_label(@focus_modal_card.content_type)}
            </div>
          </div>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={
          @focus_modal_card.content_type not in [:thinking, :streaming] &&
            !@focus_modal_card[:last_response] && !@focus_modal_card.last_tool
        }
        class="text-center py-8"
      >
        <div class="text-muted/40 text-sm">No active work to display</div>
        <div class="text-muted/30 text-xs mt-1">This agent is standing by</div>
      </div>
    </div>
    """
  end

  defp render_focus_tab(:history, assigns) do
    history = Map.get(assigns.focus_modal_card, :thought_history, [])
    agent_color = LoomkinWeb.AgentColors.agent_color(assigns.focus_modal_agent)
    assigns = assign(assigns, history: history, agent_color: agent_color)

    ~H"""
    <div class="p-5 space-y-2">
      <div :if={@history == []} class="text-center py-8">
        <.icon name="hero-clock-mini" class="w-8 h-8 text-muted/20 mx-auto mb-2" />
        <div class="text-muted/40 text-sm">No thought history yet</div>
      </div>
      <div
        :for={{entry, idx} <- Enum.with_index(@history)}
        id={"focus-thought-#{idx}"}
        class="text-sm leading-relaxed agent-card-content rounded-lg px-3 py-2"
        style={modal_thought_style(entry.type, @agent_color)}
      >
        <div class="flex items-center gap-1.5 mb-1">
          <span class={modal_thought_badge(entry.type)}>
            {modal_thought_label(entry.type)}
          </span>
          <span class="text-[9px] text-muted/40 font-mono">
            {modal_format_time(entry.timestamp)}
          </span>
        </div>
        <div class="line-clamp-8">{render_modal_markdown(entry.content)}</div>
      </div>
    </div>
    """
  end

  defp render_focus_tab(:tools, assigns) do
    last_tool = assigns.focus_modal_card.last_tool
    assigns = assign(assigns, last_tool: last_tool)

    ~H"""
    <div class="p-5 space-y-3">
      <div :if={!@last_tool} class="text-center py-8">
        <.icon name="hero-wrench-screwdriver-mini" class="w-8 h-8 text-muted/20 mx-auto mb-2" />
        <div class="text-muted/40 text-sm">No tool activity recorded</div>
      </div>

      <div :if={@last_tool} class="space-y-2">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted/60">
          Last tool execution
        </span>
        <div class="px-4 py-3 rounded-lg bg-surface-1 space-y-2">
          <div class="flex items-center gap-2">
            <span class="text-lg">{modal_tool_icon(@last_tool)}</span>
            <span class="text-sm font-medium text-primary">
              {@last_tool[:name] || @last_tool.name}
            </span>
          </div>
          <div :if={@last_tool[:target]} class="text-xs font-mono text-muted truncate">
            {@last_tool[:target]}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_focus_tab(:stats, assigns) do
    card = assigns.focus_modal_card
    thought_count = length(Map.get(card, :thought_history, []))
    budget = Map.get(card, :budget_used, 0)
    agent_color = LoomkinWeb.AgentColors.agent_color(assigns.focus_modal_agent)

    assigns =
      assigns
      |> assign(:stats_card, card)
      |> assign(:thought_count, thought_count)
      |> assign(:budget, budget)
      |> assign(:agent_color, agent_color)

    ~H"""
    <div class="p-5 space-y-4">
      <%!-- Visual state indicator --%>
      <div class="flex justify-center py-3">
        <div
          class={[
            "w-20 h-20 rounded-2xl flex items-center justify-center text-2xl font-bold relative",
            modal_state_glow(@stats_card.status)
          ]}
          style={"background: #{@agent_color}12; color: #{@agent_color};"}
        >
          {String.first(@focus_modal_agent) |> String.upcase()}
          <span class={[
            "absolute -bottom-1 -right-1 w-4 h-4 rounded-full ring-2 ring-surface-2",
            modal_status_dot(@stats_card.status)
          ]} />
        </div>
      </div>

      <%!-- Stats grid --%>
      <div class="grid grid-cols-2 gap-3">
        <div class="px-4 py-3 rounded-xl bg-surface-1 text-center">
          <div class="text-2xl font-bold tabular-nums text-primary">{@thought_count}</div>
          <div class="text-[10px] text-muted/60 uppercase tracking-wider mt-1">Thoughts</div>
        </div>
        <div class="px-4 py-3 rounded-xl bg-surface-1 text-center">
          <div class="text-2xl font-bold tabular-nums text-primary font-mono">
            {modal_format_tokens(@budget)}
          </div>
          <div class="text-[10px] text-muted/60 uppercase tracking-wider mt-1">Tokens</div>
        </div>
      </div>

      <%!-- Details list --%>
      <div class="space-y-2">
        <div class="flex items-center justify-between py-1.5 border-b border-border-subtle">
          <span class="text-xs text-muted">Role</span>
          <span class="text-xs text-secondary font-medium">
            {format_agent_role(@stats_card.role)}
          </span>
        </div>
        <div class="flex items-center justify-between py-1.5 border-b border-border-subtle">
          <span class="text-xs text-muted">Status</span>
          <span class={["text-xs font-medium", modal_status_text(@stats_card.status)]}>
            {modal_status_label(@stats_card.status)}
          </span>
        </div>
        <div class="flex items-center justify-between py-1.5">
          <span class="text-xs text-muted">Current task</span>
          <span class="text-xs text-secondary truncate max-w-[200px]">
            {@stats_card.current_task || "—"}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp render_focus_tab(_, assigns) do
    ~H"""
    <div class="text-center py-8 text-muted/40 text-sm">Unknown tab</div>
    """
  end

  # ── Focus modal helpers ──

  defp modal_status_dot(:working), do: "bg-green-400 agent-dot-working"
  defp modal_status_dot(:idle), do: "bg-zinc-500"
  defp modal_status_dot(:error), do: "bg-red-400"
  defp modal_status_dot(:paused), do: "bg-blue-400 animate-pulse"
  defp modal_status_dot(:approval_pending), do: "bg-violet-500 animate-pulse"
  defp modal_status_dot(:ask_user_pending), do: "bg-cyan-500 animate-pulse"
  defp modal_status_dot(:awaiting_synthesis), do: "bg-indigo-500 animate-pulse"
  defp modal_status_dot(:suspended_healing), do: "bg-amber-400 animate-pulse"
  defp modal_status_dot(:crashed), do: "bg-red-500 animate-pulse"
  defp modal_status_dot(:recovering), do: "bg-amber-400 animate-pulse"
  defp modal_status_dot(:complete), do: "bg-emerald-400"
  defp modal_status_dot(_), do: "bg-zinc-500"

  defp modal_status_label(:working), do: "Working"
  defp modal_status_label(:idle), do: "Idle"
  defp modal_status_label(:paused), do: "Paused"
  defp modal_status_label(:error), do: "Error"
  defp modal_status_label(:approval_pending), do: "Awaiting Approval"
  defp modal_status_label(:ask_user_pending), do: "Waiting for You"
  defp modal_status_label(:awaiting_synthesis), do: "Synthesizing"
  defp modal_status_label(:suspended_healing), do: "Healing"
  defp modal_status_label(:crashed), do: "Crashed"
  defp modal_status_label(:recovering), do: "Recovering"
  defp modal_status_label(:complete), do: "Complete"
  defp modal_status_label(:permanently_failed), do: "Failed"
  defp modal_status_label(_), do: "Unknown"

  defp modal_status_pill(:working), do: "bg-green-500/15 text-green-400"
  defp modal_status_pill(:idle), do: "bg-zinc-500/15 text-zinc-400"
  defp modal_status_pill(:paused), do: "bg-blue-500/15 text-blue-400"
  defp modal_status_pill(:error), do: "bg-red-500/15 text-red-400"
  defp modal_status_pill(:crashed), do: "bg-red-500/15 text-red-400"
  defp modal_status_pill(:approval_pending), do: "bg-violet-500/15 text-violet-400"
  defp modal_status_pill(:ask_user_pending), do: "bg-cyan-500/15 text-cyan-400"
  defp modal_status_pill(:awaiting_synthesis), do: "bg-indigo-500/15 text-indigo-400"
  defp modal_status_pill(:suspended_healing), do: "bg-amber-500/15 text-amber-400"
  defp modal_status_pill(:complete), do: "bg-emerald-500/15 text-emerald-400"
  defp modal_status_pill(_), do: "bg-zinc-500/15 text-zinc-400"

  defp modal_status_text(:working), do: "text-green-400"
  defp modal_status_text(:idle), do: "text-zinc-400"
  defp modal_status_text(:error), do: "text-red-400"
  defp modal_status_text(:crashed), do: "text-red-400"
  defp modal_status_text(:paused), do: "text-blue-400"
  defp modal_status_text(:complete), do: "text-emerald-400"
  defp modal_status_text(:approval_pending), do: "text-violet-400"
  defp modal_status_text(:suspended_healing), do: "text-amber-400"
  defp modal_status_text(_), do: "text-zinc-400"

  defp modal_state_glow(:working), do: "ring-2 ring-green-500/20 shadow-lg shadow-green-500/5"
  defp modal_state_glow(:error), do: "ring-2 ring-red-500/20 shadow-lg shadow-red-500/5"
  defp modal_state_glow(:crashed), do: "ring-2 ring-red-500/30 shadow-lg shadow-red-500/10"

  defp modal_state_glow(:approval_pending),
    do: "ring-2 ring-violet-500/20 shadow-lg shadow-violet-500/5"

  defp modal_state_glow(:suspended_healing),
    do: "ring-2 ring-amber-500/20 shadow-lg shadow-amber-500/5"

  defp modal_state_glow(_), do: ""

  defp modal_content_type_label(:thinking), do: "Thinking"
  defp modal_content_type_label(:streaming), do: "Streaming"
  defp modal_content_type_label(:message), do: "Message"
  defp modal_content_type_label(:tool_call), do: "Tool call"
  defp modal_content_type_label(:last_thinking), do: "Last thought"
  defp modal_content_type_label(:idle), do: "Idle"
  defp modal_content_type_label(nil), do: "Idle"
  defp modal_content_type_label(other), do: to_string(other)

  @modal_tool_icons %{
    "file_read" => "📄",
    "file_write" => "✍",
    "file_edit" => "✎",
    "file_search" => "🔍",
    "content_search" => "🔍",
    "directory_list" => "📁",
    "shell" => "⚡",
    "git" => "📈",
    "peer_message" => "💬",
    "peer_discovery" => "📡",
    "peer_create_task" => "📋",
    "peer_complete_task" => "✅",
    "peer_ask_question" => "❓",
    "context_offload" => "💾",
    "context_retrieve" => "📥",
    "decision_log" => "📝",
    "ask_user" => "🙋"
  }

  defp modal_tool_icon(nil), do: "⚙"
  defp modal_tool_icon(%{name: name}), do: Map.get(@modal_tool_icons, name, "⚙")
  defp modal_tool_icon(_), do: "⚙"

  defp modal_tool_label(nil), do: "—"

  defp modal_tool_label(%{target: target, name: name}) when is_binary(target) and target != "",
    do: "#{name}: #{target}"

  defp modal_tool_label(%{name: name}), do: name
  defp modal_tool_label(_), do: "—"

  defp modal_format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp modal_format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  defp modal_format_tokens(n) when is_integer(n), do: "#{n}"
  defp modal_format_tokens(_), do: "0"

  defp modal_format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp modal_format_time(_), do: ""

  defp modal_thought_style(:thinking, agent_color) do
    "color: var(--text-secondary); background: #{agent_color}06; border-left: 2px solid #{agent_color}20;"
  end

  defp modal_thought_style(:message, _agent_color) do
    "color: var(--text-secondary); background: rgba(52, 211, 153, 0.04); border-left: 2px solid rgba(52, 211, 153, 0.2);"
  end

  defp modal_thought_style(_, agent_color) do
    "color: var(--text-secondary); background: #{agent_color}04; border-left: 2px solid #{agent_color}10;"
  end

  defp modal_thought_badge(:thinking),
    do: "text-[9px] font-medium text-violet-400/70 uppercase tracking-wider"

  defp modal_thought_badge(:message),
    do: "text-[9px] font-medium text-emerald-400/70 uppercase tracking-wider"

  defp modal_thought_badge(_),
    do: "text-[9px] font-medium text-muted/50 uppercase tracking-wider"

  defp modal_thought_label(:thinking), do: "thought"
  defp modal_thought_label(:message), do: "response"
  defp modal_thought_label(type), do: to_string(type)

  defp render_modal_markdown(nil), do: ""
  defp render_modal_markdown(""), do: ""

  defp render_modal_markdown(content) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      ""
    else
      doc = MDEx.new() |> MDEx.Document.put_markdown(trimmed)

      case MDEx.to_html(doc) do
        {:ok, html} ->
          Phoenix.HTML.raw(html)

        _ ->
          {:safe, escaped} = Phoenix.HTML.html_escape(trimmed)
          Phoenix.HTML.raw("<p>#{escaped}</p>")
      end
    end
  end

  defp render_modal_markdown(_), do: ""
end
