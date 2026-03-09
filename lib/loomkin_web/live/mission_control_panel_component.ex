defmodule LoomkinWeb.MissionControlPanelComponent do
  @moduledoc """
  Left-panel LiveComponent for Mission Control mode.

  Renders the agent card grid (concierge at top, worker grid below), ghost cards for
  dormant kin, and the comms feed. Focused-agent view replaces the grid when
  `focused_agent` is set.

  All interactive events are forwarded to the parent WorkspaceLive via
  `send(self(), {:mission_control_event, event, params})`.

  Parent-provided assigns:
    - agent_cards               map of agent_name => card struct
    - concierge_card_names      list of agent names with concierge role
    - system_card_names         list of agent names with system/infrastructure roles (orienter)
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

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event(event, params, socket) do
    send(self(), {:mission_control_event, event, params})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    focused_card =
      if assigns.focused_agent do
        Map.get(assigns.agent_cards, assigns.focused_agent)
      end

    assigns = assign(assigns, :focused_card, focused_card)

    ~H"""
    <div class="flex-1 flex flex-col min-w-0 min-h-0 bg-surface-0 border-r border-subtle">
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
          class="flex-shrink-0 mx-3 mt-3 px-4 py-3 rounded-lg border border-violet-500 bg-violet-950/60 flex items-start gap-3"
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
        <%!-- Concierge — dedicated top card --%>
        <div :if={@concierge_card_names != []} class="flex-shrink-0 p-3 pb-0">
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

        <%!-- System agents (orienter etc.) — compact status, no interactive buttons --%>
        <div :if={system_card_names(assigns) != []} class="px-3 pb-2">
          <div
            :for={name <- system_card_names(assigns)}
            class="flex items-center gap-2 py-1 px-2 rounded bg-surface-1/50"
          >
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
        <div class="flex-shrink p-3 pb-0 overflow-y-auto max-h-[50%] min-h-[120px]">
          <div class="flex items-center gap-2 mb-2">
            <div class="flex items-center gap-1.5">
              <svg class="w-3.5 h-3.5 text-muted" viewBox="0 0 20 20" fill="currentColor">
                <path d="M7 8a3 3 0 100-6 3 3 0 000 6zM14.5 9a2.5 2.5 0 100-5 2.5 2.5 0 000 5zM1.615 16.428a1.224 1.224 0 01-.569-1.175 6.002 6.002 0 0111.908 0c.058.467-.172.92-.57 1.174A9.953 9.953 0 017 18a9.953 9.953 0 01-5.385-1.572zM14.5 16h-.106c.07-.297.088-.611.048-.933a7.47 7.47 0 00-1.588-3.755 4.502 4.502 0 015.874 2.636.818.818 0 01-.36.98A7.465 7.465 0 0114.5 16z" />
              </svg>
              <span class="text-xs font-medium text-muted uppercase tracking-wider">Kin</span>
            </div>
            <span class="text-[10px] tabular-nums px-1.5 py-0.5 rounded-full font-medium text-muted bg-surface-2">
              {length(@worker_card_names)}
            </span>
            <div class="flex-1 h-px bg-border-subtle"></div>
            {render_collab_health(assigns)}
          </div>

          <%!-- Waiting state: session exists but agents haven't spawned yet --%>
          <div
            :if={@concierge_card_names == [] && @worker_card_names == [] && @active_team_id}
            class="rounded-lg py-4 px-4 text-center bg-surface-1 border border-subtle"
          >
            <div class="flex justify-center mb-2">
              <div class="w-8 h-8 rounded-full bg-violet-500/15 flex items-center justify-center text-violet-400 text-xs font-bold">
                C
              </div>
            </div>
            <div class="text-xs font-medium text-secondary">
              Concierge ready
            </div>
            <div class="text-[10px] mt-0.5 text-muted">
              Send a message to get started
            </div>
          </div>
          <%!-- No session state --%>
          <div
            :if={@concierge_card_names == [] && @worker_card_names == [] && !@active_team_id}
            class="rounded-lg border border-dashed border-subtle py-4 px-4 text-center"
          >
            <div class="text-muted text-xs">Start a session to meet your kin</div>
            <div class="text-[10px] mt-0.5 text-muted">
              Concierge + Orienter spawn automatically
            </div>
          </div>

          <%!-- Ghost cards for dormant kin (not yet spawned) --%>
          {render_ghost_cards(assigns)}

          <%= if @worker_card_names != [] do %>
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

        <%!-- Comms Feed (scrollable, takes remaining space) --%>
        <%= if @comms_stream do %>
          <div class="flex-1 overflow-auto min-h-[200px] border-t border-subtle">
            <LoomkinWeb.AgentCommsComponent.comms_feed
              stream={@comms_stream}
              event_count={@comms_event_count}
              id="agent-comms"
              root_team_id={@active_team_id}
            />
          </div>
        <% end %>
      <% end %>
    </div>
    """
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
          class="group flex items-center gap-2 px-3 py-2 rounded-lg border border-dashed border-subtle transition-all hover:border-solid hover:bg-surface-2"
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
        class="mt-2 rounded-lg border border-dashed border-subtle py-6 px-4 text-center"
      >
        <div class="text-muted text-xs">No kin specialists available yet</div>
        <div class="text-[10px] mt-1 text-muted">
          The concierge will spawn agents as needed
        </div>
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

  defp card_grid_cols(_), do: "grid-cols-2 lg:grid-cols-3"

  defp any_agents_active?(agent_cards, card_names) do
    Enum.any?(card_names, fn name ->
      card = agent_cards[name]
      card && card.content_type in [:thinking, :tool_call, :streaming]
    end)
  end

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
end
