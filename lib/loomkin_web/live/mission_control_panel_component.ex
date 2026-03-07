defmodule LoomkinWeb.MissionControlPanelComponent do
  @moduledoc """
  Left-panel LiveComponent for Mission Control mode.

  Renders the agent card grid (concierge at top, worker grid below), ghost cards for
  dormant kin, and the comms feed. Focused-agent view replaces the grid when
  `focused_agent` is set.

  All interactive events are forwarded to the parent WorkspaceLive via
  `send(self(), {:mission_control_event, event, params})`.

  Parent-provided assigns:
    - agent_cards          map of agent_name => card struct
    - concierge_card_names list of agent names with concierge role
    - worker_card_names    list of agent names with worker roles
    - comms_event_count    integer
    - focused_agent        binary | nil
    - kin_agents           list of kin structs
    - cached_agents        list of cached agent structs
    - active_team_id       binary | nil
    - comms_stream         the @streams.comms_events value (may be nil in tests)
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

        <%!-- Team Agents Section --%>
        <div class="flex-shrink-0 p-3 pb-0">
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
          </div>

          <%!-- Waiting state: session exists but agents haven't spawned yet --%>
          <div
            :if={@concierge_card_names == [] && @worker_card_names == [] && @active_team_id}
            class="rounded-lg py-4 px-4 text-center bg-surface-1 border border-subtle"
          >
            <div class="flex justify-center gap-3 mb-2">
              <div class="w-8 h-8 rounded-full bg-violet-500/15 flex items-center justify-center text-violet-400 text-xs font-bold">
                C
              </div>
              <div class="w-8 h-8 rounded-full bg-sky-500/15 flex items-center justify-center text-sky-400 text-xs font-bold">
                O
              </div>
            </div>
            <div class="text-xs font-medium text-secondary">
              Concierge & Orienter ready
            </div>
            <div class="text-[10px] mt-0.5 text-muted">
              Send a message to wake them up
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
          <div class="flex-1 overflow-auto min-h-0 border-t border-subtle">
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
    <div :if={@dormant_kin != []} class="flex flex-wrap gap-2 mt-2">
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
    """
  end

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
end
