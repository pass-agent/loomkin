defmodule LoomkinWeb.ComposerComponent do
  @moduledoc """
  LiveComponent for the message composer input bar.

  Owns its own UI state (show_agent_picker, schedule_popover, schedule_delay_minutes).
  Receives read-only assigns from the parent LiveView.

  Events that affect parent state are forwarded via:
    send(self(), {:composer_event, event, params})

  Events handled locally:
    toggle_agent_picker, close_agent_picker,
    toggle_scheduler, close_scheduler, set_schedule_delay
  """

  use LoomkinWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:show_agent_picker, fn -> false end)
      |> assign_new(:schedule_popover, fn -> false end)
      |> assign_new(:schedule_delay_minutes, fn -> 5 end)
      |> assign_new(:agent_count, fn -> 0 end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_agent_picker", _params, socket) do
    {:noreply, assign(socket, show_agent_picker: !socket.assigns.show_agent_picker)}
  end

  def handle_event("close_agent_picker", _params, socket) do
    {:noreply, assign(socket, show_agent_picker: false)}
  end

  def handle_event("toggle_scheduler", _params, socket) do
    {:noreply, assign(socket, schedule_popover: !socket.assigns.schedule_popover)}
  end

  def handle_event("close_scheduler", _params, socket) do
    {:noreply, assign(socket, schedule_popover: false)}
  end

  def handle_event("set_schedule_delay", %{"minutes" => minutes}, socket) do
    case Integer.parse(minutes) do
      {val, _} when val > 0 -> {:noreply, assign(socket, schedule_delay_minutes: val)}
      _ -> {:noreply, socket}
    end
  end

  # Forward these events to the parent LiveView
  def handle_event("send_message", params, socket) do
    send(self(), {:composer_event, "send_message", params})
    {:noreply, socket}
  end

  def handle_event("cancel_reply", params, socket) do
    send(self(), {:composer_event, "cancel_reply", params})
    {:noreply, socket}
  end

  def handle_event("select_reply_target", params, socket) do
    send(self(), {:composer_event, "select_reply_target", params})
    {:noreply, assign(socket, show_agent_picker: false)}
  end

  def handle_event("toggle_queue_from_composer", params, socket) do
    send(self(), {:composer_event, "toggle_queue_from_composer", params})
    {:noreply, socket}
  end

  def handle_event("enqueue_message", params, socket) do
    send(self(), {:composer_event, "enqueue_message", params})
    {:noreply, socket}
  end

  def handle_event("inject_guidance", params, socket) do
    send(self(), {:composer_event, "inject_guidance", params})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    agents = assigns[:cached_agents] || []
    assigns = assign(assigns, :picker_agents, agents)

    ~H"""
    <div class="flex-shrink-0 composer-container">
      <.render_last_message_strip last_user_message={@last_user_message} />
      <form phx-submit="send_message" phx-target={@myself} class="px-4 pb-4 pt-2 sm:px-6 sm:pb-5">
        <%!-- Reply indicator with role icon --%>
        <div
          :if={@reply_target}
          class="flex items-center gap-2 mb-3 px-3 py-1.5 rounded-xl animate-fade-in bg-brand-subtle/40"
        >
          <span class="text-sm">{role_icon_for(@reply_target.agent, @agent_cards)}</span>
          <span class="inline-flex items-center px-1.5 py-px rounded-md text-[10px] font-semibold bg-brand/15 text-brand">
            {@reply_target.agent}
          </span>
          <span class="text-[11px] text-muted/60">Replying</span>
          <button
            type="button"
            phx-click="cancel_reply"
            phx-target={@myself}
            class="ml-auto rounded-full p-1 transition-colors hover:bg-surface-3/50 text-muted/40 hover:text-secondary"
            data-tooltip="Cancel reply"
            aria-label="Cancel reply"
          >
            <.icon name="hero-x-mark-mini" class="w-3 h-3" />
          </button>
        </div>

        <%!-- The floating composer card --%>
        <div class="composer-card">
          <%!-- Input row --%>
          <div class="flex items-end gap-3 p-3">
            <%!-- Left: Agent picker --%>
            <div class="relative flex-shrink-0 self-center">
              <button
                type="button"
                phx-click="toggle_agent_picker"
                phx-target={@myself}
                class={[
                  "composer-icon-btn",
                  @reply_target && "composer-icon-btn-active"
                ]}
                data-tooltip={
                  if @reply_target,
                    do: "Replying to #{@reply_target.agent}",
                    else: "Send to concierge"
                }
                aria-label={
                  if @reply_target,
                    do: "Replying to #{@reply_target.agent}",
                    else: "Send to concierge"
                }
              >
                <.icon name="hero-at-symbol-mini" class="w-4 h-4" />
              </button>

              <%!-- Agent picker dropdown --%>
              <div
                :if={@show_agent_picker}
                class="composer-dropdown absolute bottom-full left-0 mb-2 w-56 max-h-64 overflow-y-auto py-1 z-50 animate-scale-in"
                phx-click-away="close_agent_picker"
                phx-target={@myself}
              >
                <div class="px-3 py-2">
                  <span class="text-[10px] font-semibold uppercase tracking-widest text-muted/60">
                    Send to
                  </span>
                </div>
                <button
                  :for={agent <- @picker_agents}
                  type="button"
                  phx-click="select_reply_target"
                  phx-value-agent={agent.name}
                  phx-value-team-id={agent.team_id}
                  phx-target={@myself}
                  class={[
                    "flex items-center gap-2 w-full px-3 py-2 text-left text-xs transition-colors hover:bg-surface-3/30",
                    @reply_target && @reply_target.agent == agent.name && "bg-surface-3/20"
                  ]}
                >
                  <span class="text-sm flex-shrink-0">
                    {LoomkinWeb.AgentColors.role_icon(agent[:role])}
                  </span>
                  <span class="truncate" style={"color: #{agent_color(agent.name)};"}>
                    {agent.name}
                  </span>
                  <span class="ml-auto text-[10px] text-muted/60">
                    {format_role_label(agent[:role]) || agent[:status]}
                  </span>
                </button>
              </div>
            </div>

            <%!-- Center: Textarea --%>
            <div class="flex-1 min-w-0">
              <textarea
                name="text"
                rows="1"
                aria-label="Message to concierge"
                placeholder={
                  if @reply_target,
                    do: "Reply to #{@reply_target.agent}...",
                    else: "Message concierge..."
                }
                class="composer-input"
                phx-hook="ShiftEnterSubmit"
                id="message-input"
              ><%= @input_text %></textarea>
            </div>

            <%!-- Right: Send / Stop --%>
            <div class="flex-shrink-0 self-center">
              <button
                :if={@status != :thinking}
                type="submit"
                class={[
                  "composer-send-btn",
                  if(@status == :idle,
                    do: "composer-send-btn-ready",
                    else: "composer-send-btn-disabled"
                  )
                ]}
                disabled={@status != :idle}
                data-tooltip="Send message"
                aria-label="Send message"
              >
                <svg
                  class="w-4 h-4"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2.5"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5"
                  />
                </svg>
              </button>
              <button
                :if={@status == :thinking}
                type="button"
                phx-click="cancel"
                class="composer-stop-btn"
                data-tooltip="Stop generation"
                aria-label="Stop generation"
              >
                <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                  <rect x="6" y="6" width="12" height="12" rx="2" />
                </svg>
              </button>
            </div>
          </div>

          <%!-- Bottom toolbar — secondary actions, neatly aligned --%>
          <div class="flex items-center gap-1 px-3 pb-2.5 pt-0">
            <%!-- Queue --%>
            <button
              :if={@reply_target}
              type="button"
              phx-click="toggle_queue_from_composer"
              phx-target={@myself}
              class="composer-icon-btn"
              data-tooltip={"View #{@reply_target.agent}'s queue"}
              aria-label={"View #{@reply_target.agent}'s queue"}
            >
              <.icon name="hero-queue-list-mini" class="w-3.5 h-3.5" />
            </button>

            <%!-- Schedule --%>
            <div :if={@status != :thinking} class="relative">
              <button
                type="button"
                phx-click="toggle_scheduler"
                phx-target={@myself}
                class={["composer-icon-btn", @schedule_popover && "composer-icon-btn-active"]}
                data-tooltip="Schedule"
                aria-label="Schedule message"
              >
                <.icon name="hero-clock-mini" class="w-3.5 h-3.5" />
              </button>

              <LoomkinWeb.ScheduleMessageComponent.schedule_popover
                :if={@schedule_popover}
                target_agent={if(@reply_target, do: @reply_target.agent)}
                content={@input_text}
                delay_minutes={@schedule_delay_minutes}
                scheduled_messages={@scheduled_messages}
                phx_target={@myself}
              />
            </div>

            <%!-- Enqueue --%>
            <button
              :if={@status != :thinking && @reply_target}
              type="button"
              phx-click="enqueue_message"
              phx-target={@myself}
              class="composer-icon-btn"
              data-tooltip={"Add to #{@reply_target.agent}'s queue"}
              aria-label={"Add to #{@reply_target.agent}'s queue"}
            >
              <.icon name="hero-plus-mini" class="w-3.5 h-3.5" />
            </button>

            <%!-- Guide --%>
            <button
              :if={
                @status != :thinking && @reply_target &&
                  agent_is_working?(assigns[:agent_cards] || %{}, @reply_target.agent)
              }
              type="button"
              phx-click="inject_guidance"
              phx-target={@myself}
              class="composer-icon-btn text-emerald-400/60 hover:text-emerald-400"
              data-tooltip={"Guide #{@reply_target.agent}"}
            >
              <.icon name="hero-map-pin-mini" class="w-3.5 h-3.5" />
            </button>

            <%!-- Spacer --%>
            <div class="flex-1" />

            <%!-- Keyboard hints --%>
            <span class="text-[10px] text-muted/30 hidden sm:inline">
              <kbd class="font-mono text-[9px]">&#8679;&#9166;</kbd> new line
            </span>
          </div>
        </div>
      </form>
    </div>
    """
  end

  # --- Sub-renders ---

  defp render_last_message_strip(%{last_user_message: nil} = assigns) do
    ~H""
  end

  defp render_last_message_strip(assigns) do
    ~H"""
    <div class="flex-shrink-0 px-6 py-1.5 flex items-center gap-2 overflow-hidden">
      <span class="text-[10px] font-semibold text-muted/60 uppercase tracking-widest flex-shrink-0">
        You
      </span>
      <span class="text-[10px] flex-shrink-0 text-muted/40">&rarr;</span>
      <span class="text-[10px] font-medium flex-shrink-0 text-brand/80">
        {@last_user_message.to}
      </span>
      <span class="text-[11px] truncate flex-1 min-w-0 text-secondary/70">
        {@last_user_message.text}
      </span>
    </div>
    """
  end

  # --- Helpers ---

  defp agent_color(name), do: LoomkinWeb.AgentColors.agent_color(name)

  defp role_icon_for(agent_name, agent_cards) when is_map(agent_cards) do
    case Map.get(agent_cards, agent_name) do
      %{role: role} -> LoomkinWeb.AgentColors.role_icon(role)
      _ -> "◆"
    end
  end

  defp role_icon_for(_, _), do: "◆"

  defp format_role_label(nil), do: nil
  defp format_role_label(role) when is_atom(role), do: format_role_label(to_string(role))

  defp format_role_label(role) when is_binary(role) do
    role |> String.replace("_", " ") |> String.capitalize()
  end

  defp agent_is_working?(agent_cards, agent_name) do
    case Map.get(agent_cards, agent_name) do
      %{status: :working} -> true
      _ -> false
    end
  end
end
