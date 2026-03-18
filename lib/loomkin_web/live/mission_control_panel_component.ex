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
    - system_card_names         list of agent names with system/infrastructure roles (weaver)
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

    assigns =
      assigns
      |> assign(:focused_card, focused_card)
      |> assign(:active_workers, active_workers)
      |> assign(:idle_workers, idle_workers)

    ~H"""
    <div class="flex-1 flex flex-col min-w-0 min-h-0 bg-surface-0">
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
          class="flex-shrink-0 mx-4 mt-3 px-4 py-3 rounded-xl border border-violet-500/50 bg-violet-950/40 backdrop-blur-sm flex items-start gap-3"
        >
          <div class="w-2 h-2 rounded-full bg-violet-400 animate-pulse mt-1 flex-shrink-0"></div>
          <div class="flex-1 min-w-0">
            <p class="text-xs font-semibold text-violet-300 uppercase tracking-wider mb-1">
              Team leader awaiting your approval
            </p>
            <p class="text-sm text-gray-200 truncate">
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

        <%!-- Concierge — ALWAYS visible, pinned above tabs --%>
        <div :if={@concierge_card_names != []} class="flex-shrink-0 px-4 pt-3 pb-1">
          <.live_component
            :for={name <- @concierge_card_names}
            module={LoomkinWeb.AgentCardComponent}
            id={"agent-card-#{name}"}
            card={@agent_cards[name]}
            focused={false}
            team_id={@active_team_id}
            model={@agent_cards[name][:model]}
          />
        </div>

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
        </div>

        <%= if @active_tab == :kin do %>
          <%!-- System agents (weaver etc.) — compact status with role identity --%>
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
                  <.live_component
                    :for={name <- @active_workers}
                    module={LoomkinWeb.AgentCardComponent}
                    id={"agent-card-#{name}"}
                    card={@agent_cards[name]}
                    focused={false}
                    team_id={@active_team_id}
                    model={@agent_cards[name][:model]}
                  />
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
                    <button
                      :for={name <- @idle_workers}
                      phx-click="focus_card_agent"
                      phx-value-agent={name}
                      class="idle-agent-row group w-full flex items-center gap-2.5 px-3 py-2 rounded-lg transition-all duration-150 hover:bg-surface-2/80 cursor-pointer"
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
                        :if={@agent_cards[name] && !role_matches_name?(@agent_cards[name].role, name)}
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
                      <%!-- Reply button on hover --%>
                      <span class="ml-auto opacity-0 group-hover:opacity-60 transition-opacity flex-shrink-0">
                        <.icon name="hero-chat-bubble-left-mini" class="w-3 h-3 text-muted" />
                      </span>
                    </button>
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
    "tester" => "🧪",
    "weaver" => "🕸"
  }

  @role_accents %{
    "lead" => "#cba6f7",
    "concierge" => "#f9e2af",
    "researcher" => "#89dceb",
    "coder" => "#a6e3a1",
    "reviewer" => "#fab387",
    "tester" => "#f38ba8",
    "weaver" => "#94e2d5"
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
end
