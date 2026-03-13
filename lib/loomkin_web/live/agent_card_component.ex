defmodule LoomkinWeb.AgentCardComponent do
  @moduledoc """
  LiveComponent that renders a single agent's workbench card in
  the mission control UI. Each agent gets one card that updates in-place,
  showing status, current activity, and action buttons.

  As a LiveComponent, only the card whose assigns change will re-render,
  and MDEx markdown rendering is memoized so it only runs when content
  actually changes.
  """

  use LoomkinWeb, :live_component

  @tool_config %{
    "file_read" => %{icon: "📄", color: "#818cf8"},
    "file_write" => %{icon: "✍", color: "#34d399"},
    "file_edit" => %{icon: "✎", color: "#fbbf24"},
    "file_search" => %{icon: "🔍", color: "#22d3ee"},
    "content_search" => %{icon: "🔍", color: "#22d3ee"},
    "directory_list" => %{icon: "📁", color: "#a78bfa"},
    "shell" => %{icon: "⚡", color: "#f472b6"},
    "git" => %{icon: "📈", color: "#fb923c"}
  }
  @default_tool_config %{icon: "⚙", color: "#71717a"}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       card: nil,
       focused: false,
       team_id: nil,
       model: nil,
       rendered_content: "",
       prev_content: nil,
       prev_content_type: nil,
       prev_focused: nil,
       rendered_last_response: nil,
       prev_last_response: nil,
       capability_bars_data: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    card = socket.assigns.card
    focused = socket.assigns.focused
    team_id = socket.assigns.team_id

    new_content = card && card.latest_content
    new_content_type = card && card.content_type
    old_content = socket.assigns.prev_content
    old_content_type = socket.assigns.prev_content_type
    old_focused = socket.assigns.prev_focused

    new_last_response = card && card[:last_response]
    old_last_response = socket.assigns[:prev_last_response]

    socket =
      if new_content != old_content || new_content_type != old_content_type ||
           focused != old_focused do
        rendered = render_card_markdown(format_content(new_content, focused))

        assign(socket,
          rendered_content: rendered,
          prev_content: new_content,
          prev_content_type: new_content_type,
          prev_focused: focused
        )
      else
        socket
      end

    socket =
      if new_last_response != old_last_response do
        rendered_last = render_card_markdown(format_content(new_last_response, false))

        assign(socket,
          rendered_last_response: rendered_last,
          prev_last_response: new_last_response
        )
      else
        socket
      end

    caps =
      if team_id && card do
        Loomkin.Teams.Capabilities.get_capabilities(team_id, card.name)
        |> Enum.take(3)
      else
        []
      end

    socket = assign(socket, :capability_bars_data, caps)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    color = LoomkinWeb.AgentColors.agent_color(assigns.card.name)
    assigns = assign(assigns, :agent_color, color)

    ~H"""
    <div
      id={"agent-card-#{@card.name}"}
      role="button"
      tabindex={if @focused, do: "-1", else: "0"}
      aria-label={"#{@card.name} — #{status_label(@card.status)}"}
      phx-click="focus_card_agent"
      phx-keydown="focus_card_agent"
      phx-key="Enter"
      phx-value-agent={@card.name}
      class={[
        "group relative animate-fade-in flex flex-row overflow-hidden kin-card",
        if(@focused,
          do: "card-brand card-focused-glow h-full rounded-lg",
          else: "min-h-[140px] cursor-pointer kin-card-idle rounded-lg"
        ),
        card_state_class(@card.content_type, @card.status),
        !@focused && status_ring_class(@card.status),
        @card[:new] && "agent-card-enter",
        @card[:terminated] && "agent-card-terminated"
      ]}
      style={card_style(@card.content_type, @card.last_tool, @agent_color, @focused)}
    >
      <%!-- Left accent bar — agent identity --%>
      <div
        :if={!@focused}
        class="w-[3px] flex-shrink-0 kin-accent-bar"
        style={"background: #{@agent_color};"}
      />

      <%!-- Ambient color wash --%>
      <div
        class="absolute inset-0 pointer-events-none"
        style={"background: radial-gradient(ellipse at 0% 0%, #{@agent_color}08 0%, transparent 60%);"}
      />

      <div class="relative flex flex-col flex-1 min-h-0 min-w-0 p-4">
        <%!-- Corner notch decoration --%>
        <div
          :if={!@focused}
          class="absolute top-0 right-0 w-3 h-3"
          style="background: linear-gradient(225deg, var(--surface-0) 50%, transparent 50%); opacity: 0.6;"
        />

        <%!-- Header --%>
        <div class="flex items-start gap-2.5">
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5">
              <span
                class={[
                  "w-1.5 h-1.5 rounded-full flex-shrink-0 status-dot-transition",
                  status_dot_class(@card.status)
                ]}
                aria-hidden="true"
              />
              <span class="sr-only">{status_label(@card.status)}</span>
              <span class={[
                "text-[9px] font-medium px-1.5 py-0.5 rounded-full",
                status_pill_class(@card.status)
              ]}>
                {status_label(@card.status)}
              </span>
              <span
                class="text-[13px] font-semibold truncate tracking-tight"
                style={"color: #{@agent_color};"}
              >
                {@card.name}
              </span>
              <span
                :if={@card[:crash_count] && @card[:crash_count] > 0}
                class="ml-1 px-1 py-0.5 text-[8px] font-mono bg-red-900/50 text-red-300 rounded"
              >
                {"#{@card[:crash_count]}x crashed"}
              </span>
              <span
                :if={@card[:stuck_warning]}
                class="ml-1 px-1 py-0.5 text-[8px] font-mono bg-amber-900/50 text-amber-300 rounded animate-pulse"
                title={stuck_tooltip(@card)}
              >
                {stuck_label(@card)}
              </span>
              <span
                :if={@card[:conflict]}
                class="ml-1 px-1 py-0.5 text-[8px] font-mono bg-red-900/50 text-red-300 rounded animate-pulse"
                title={conflict_tooltip(@card)}
              >
                {conflict_label(@card)}
              </span>
              <span
                :if={@card[:pause_queued]}
                class="ml-1 px-1 py-0.5 text-[8px] font-mono bg-blue-900/50 text-blue-300 rounded animate-pulse"
              >
                pause queued
              </span>
              <span :if={@card[:previous_status]} class="text-[8px] text-muted ml-1">
                from: {@card[:previous_status]}
              </span>
            </div>
            <div class="flex items-center gap-1.5 mt-0.5">
              <span
                :if={!role_matches_name?(@card.role, @card.name)}
                class="text-[9px] font-mono uppercase tracking-widest"
                style={"color: #{@agent_color}60;"}
              >
                {format_role(@card.role)}
              </span>
              <span
                :if={@model}
                class="text-[9px] font-mono text-muted opacity-40 truncate max-w-[80px]"
              >
                {format_model(@model)}
              </span>
              <span
                :if={@card[:team_id] && @team_id && @card[:team_id] != @team_id}
                class="text-[9px] font-mono px-1.5 py-0.5 rounded-full bg-zinc-800 text-zinc-400 border border-zinc-700/50"
              >
                {short_team_label(@card[:team_id])}
              </span>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div
            class="flex items-center gap-0.5 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
            style="transition: opacity var(--transition-base);"
          >
            <button
              phx-click="reply_to_card_agent"
              phx-value-agent={@card.name}
              phx-value-team-id={@team_id}
              aria-label={"Reply to #{@card.name}"}
              class="text-muted hover:text-brand p-1 rounded hover:bg-surface-3 flex-shrink-0"
              style="transition: color var(--transition-base), background var(--transition-base);"
            >
              <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path
                  fill-rule="evenodd"
                  d="M7.707 3.293a1 1 0 010 1.414L5.414 7H11a7 7 0 017 7v2a1 1 0 11-2 0v-2a5 5 0 00-5-5H5.414l2.293 2.293a1 1 0 11-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
            <button
              :if={@card.status == :working}
              phx-click="pause_card_agent"
              phx-value-agent={@card.name}
              phx-value-team-id={@team_id}
              aria-label={"Pause #{@card.name}"}
              class="text-muted hover:text-amber-400 p-1 rounded hover:bg-surface-3 flex-shrink-0"
              style="transition: color var(--transition-base), background var(--transition-base);"
            >
              <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zM7 8a1 1 0 012 0v4a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v4a1 1 0 102 0V8a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
            <div :if={@card.status == :waiting_permission} class="flex items-center gap-1">
              <span
                class="text-[9px] text-amber-300/70 truncate max-w-[6rem]"
                title={@card[:pending_tool]}
              >
                {@card[:pending_tool] || "permission"}
              </span>
            </div>
            <button
              :if={@card.status == :waiting_permission}
              phx-click="force_pause_card_agent"
              phx-value-agent={@card.name}
              phx-value-team-id={@team_id}
              aria-label={"Force pause #{@card.name} (cancels pending permission)"}
              title="Force pause (cancels pending permission)"
              class="text-muted hover:text-red-400 p-1 rounded hover:bg-surface-3 flex-shrink-0"
              style="transition: color var(--transition-base), background var(--transition-base);"
              data-confirm="This will cancel the pending permission request. Continue?"
            >
              <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zM7 8a1 1 0 012 0v4a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v4a1 1 0 102 0V8a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
            <button
              :if={@card.status == :paused}
              phx-click="steer_card_agent"
              phx-value-agent={@card.name}
              phx-value-team-id={@team_id}
              aria-label={"Steer #{@card.name}"}
              class="text-muted hover:text-brand p-1 rounded hover:bg-surface-3 flex-shrink-0"
              style="transition: color var(--transition-base), background var(--transition-base);"
            >
              <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
              </svg>
            </button>
          </div>
        </div>

        <%!-- Capability bars --%>
        <.capability_bars
          :if={@team_id && !@focused}
          caps={@capability_bars_data}
        />

        <%!-- Content area --%>
        <div class={["mt-3 flex-1 min-h-0", @focused && "overflow-auto"]}>
          <%= case @card.content_type do %>
            <% :thinking -> %>
              <div
                class={[
                  "text-xs leading-relaxed agent-card-content kin-thought-well",
                  !@focused && "line-clamp-4"
                ]}
                style={"color: var(--text-secondary); --kin-color: #{@agent_color};"}
              >
                {@rendered_content}
              </div>
            <% :last_thinking -> %>
              <div
                class={[
                  "text-xs leading-relaxed opacity-60 agent-card-content pl-2",
                  !@focused && "line-clamp-3"
                ]}
                style={"color: var(--text-secondary); border-left: 1px solid #{@agent_color}30;"}
              >
                {@rendered_content}
              </div>
            <% :message -> %>
              <div
                class={[
                  "text-xs leading-relaxed agent-card-content",
                  !@focused && "line-clamp-4"
                ]}
                style="color: var(--text-secondary);"
              >
                {@rendered_content}
              </div>
            <% _ -> %>
              <%= cond do %>
                <% @rendered_last_response -> %>
                  <div
                    class={[
                      "text-xs leading-relaxed opacity-60 agent-card-content",
                      !@focused && "line-clamp-3"
                    ]}
                    style="color: var(--text-secondary);"
                  >
                    {@rendered_last_response}
                  </div>
                <% @card.status == :complete -> %>
                  <div class="flex items-center gap-2 text-xs">
                    <div class="h-px flex-1" style={"background: #{@agent_color}15;"} />
                    <span style={"color: #{@agent_color}80;"}>complete</span>
                    <div class="h-px flex-1" style={"background: #{@agent_color}15;"} />
                  </div>
                <% true -> %>
                  <div class="flex items-center gap-2 text-[10px] text-muted font-mono">
                    <span class="kin-idle-blink" style={"color: #{@agent_color}40;"}>_</span>
                    <span class="opacity-40">standby</span>
                  </div>
              <% end %>
          <% end %>

          <%!-- Last tool readout --%>
          <div
            :if={@card.last_tool}
            class="mt-2 flex items-center gap-1.5 font-mono"
          >
            <span
              class="text-[9px] flex-shrink-0"
              style={"color: #{tool_config(@card.last_tool.name).color};"}
            >
              {tool_config(@card.last_tool.name).icon}
            </span>
            <span class="text-[9px] truncate text-muted opacity-50">
              {@card.last_tool.target || @card.last_tool.name}
            </span>
          </div>
        </div>

        <%!-- Footer: task readout --%>
        <div
          :if={@card.current_task}
          class="mt-auto pt-2 flex items-center gap-2 font-mono"
        >
          <span
            class="text-[8px] uppercase tracking-[0.15em] flex-shrink-0 font-semibold"
            style={"color: #{@agent_color}50;"}
          >
            tsk
          </span>
          <span class="text-[10px] truncate flex-1 text-muted">
            {@card.current_task}
          </span>
        </div>
      </div>

      <%!-- Checkpoint approval panel — visible when status is :approval_pending and type is not :spawn_gate --%>
      <div
        :if={
          @card.status == :approval_pending && @card[:pending_approval] &&
            @card[:pending_approval][:type] != :spawn_gate
        }
        class="border-t border-violet-500/30 bg-violet-950/20 px-4 py-3 flex flex-col gap-2"
      >
        <div class="flex items-center justify-between gap-2">
          <span class="text-[11px] font-semibold text-violet-400">Approval required</span>
          <%!--
            started_at is fixed at the moment the gate opens and never changes,
            so this deadline is stable across LiveView re-renders and will not
            reset the CountdownTimer hook on patches.
          --%>
          <span
            id={"countdown-#{@card.name}"}
            phx-hook="CountdownTimer"
            data-deadline-at={
              @card[:pending_approval][:started_at] + @card[:pending_approval][:timeout_ms]
            }
            class="text-[10px] font-mono text-violet-300/70 tabular-nums"
          >
            --:--
          </span>
        </div>

        <p class="text-xs text-zinc-300 leading-relaxed">
          {@card[:pending_approval][:question]}
        </p>

        <%!-- Three-button row --%>
        <div class="flex items-center gap-1.5 mt-1">
          <button
            phx-click="approve_card_agent"
            phx-value-gate_id={@card[:pending_approval][:gate_id]}
            phx-value-agent={@card.name}
            phx-value-context=""
            phx-disable-with="Approving..."
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-violet-600/80 hover:bg-violet-600 text-white border border-violet-500/50 transition-colors cursor-pointer"
          >
            Approve
          </button>
          <button
            phx-click={JS.toggle(to: "#approve-ctx-#{@card.name}")}
            type="button"
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-violet-800/60 hover:bg-violet-700/60 text-violet-200 border border-violet-600/30 transition-colors cursor-pointer"
          >
            Approve w/ Context
          </button>
          <button
            phx-click={JS.toggle(to: "#deny-ctx-#{@card.name}")}
            type="button"
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-rose-900/40 hover:bg-rose-800/50 text-rose-300 border border-rose-700/30 transition-colors cursor-pointer"
          >
            Deny
          </button>
        </div>

        <%!-- Approve w/ Context form (hidden by default) --%>
        <form
          id={"approve-ctx-#{@card.name}"}
          phx-submit="approve_card_agent"
          class="hidden flex-col gap-1.5 mt-1"
        >
          <textarea
            name="context"
            rows="2"
            placeholder="Optional context for the agent..."
            class="w-full text-xs bg-zinc-900/60 border border-violet-500/30 rounded px-2 py-1.5 text-zinc-200 placeholder-zinc-500 resize-none focus:outline-none focus:border-violet-400/60"
          ></textarea>
          <input type="hidden" name="gate_id" value={@card[:pending_approval][:gate_id]} />
          <input type="hidden" name="agent" value={@card.name} />
          <button
            type="submit"
            phx-disable-with="Approving..."
            class="self-start px-3 py-1 text-[11px] font-medium rounded bg-violet-600/80 hover:bg-violet-600 text-white border border-violet-500/50 transition-colors cursor-pointer"
          >
            Send Approval
          </button>
        </form>

        <%!-- Deny form (hidden by default) --%>
        <form
          id={"deny-ctx-#{@card.name}"}
          phx-submit="deny_card_agent"
          class="hidden flex-col gap-1.5 mt-1"
        >
          <textarea
            name="reason"
            rows="2"
            placeholder="Reason for denial (optional)..."
            class="w-full text-xs bg-zinc-900/60 border border-rose-700/30 rounded px-2 py-1.5 text-zinc-200 placeholder-zinc-500 resize-none focus:outline-none focus:border-rose-600/50"
          ></textarea>
          <input type="hidden" name="gate_id" value={@card[:pending_approval][:gate_id]} />
          <input type="hidden" name="agent" value={@card.name} />
          <button
            type="submit"
            phx-disable-with="Denying..."
            class="self-start px-3 py-1 text-[11px] font-medium rounded bg-rose-900/50 hover:bg-rose-800/60 text-rose-300 border border-rose-700/30 transition-colors cursor-pointer"
          >
            Confirm Denial
          </button>
        </form>
      </div>

      <%!-- Spawn gate panel — visible when status is :approval_pending and type is :spawn_gate --%>
      <div
        :if={
          @card.status == :approval_pending && @card[:pending_approval] &&
            @card[:pending_approval][:type] == :spawn_gate
        }
        class="border-t border-violet-500/30 bg-violet-950/20 px-4 py-3 flex flex-col gap-2"
      >
        <%!-- Header row: label + countdown --%>
        <div class="flex items-center justify-between gap-2">
          <span class="text-[11px] font-semibold text-violet-400">Spawn approval required</span>
          <%!--
            started_at is fixed at the moment the gate opens and never changes,
            so this deadline is stable across LiveView re-renders and will not
            reset the CountdownTimer hook on patches.
          --%>
          <span
            id={"spawn-countdown-#{@card.name}"}
            phx-hook="CountdownTimer"
            data-deadline-at={
              @card[:pending_approval][:started_at] + @card[:pending_approval][:timeout_ms]
            }
            class="text-[10px] font-mono text-violet-300/70 tabular-nums"
          >
            --:--
          </span>
        </div>

        <%!-- Team name + cost --%>
        <div class="flex items-center justify-between gap-2">
          <p class="text-sm font-medium text-zinc-200">
            {@card[:pending_approval][:team_name]}
          </p>
          <span class="text-[10px] tabular-nums text-violet-300/80 flex-shrink-0">
            {"~$#{Float.round(@card[:pending_approval][:estimated_cost] || 0.0, 2)}"}
          </span>
        </div>

        <%!-- Purpose --%>
        <p
          :if={@card[:pending_approval][:purpose]}
          class="text-xs text-zinc-300 leading-relaxed"
        >
          {@card[:pending_approval][:purpose]}
        </p>

        <%!-- Role composition — individual agents --%>
        <div class="flex flex-wrap gap-1.5">
          <span
            :for={role <- @card[:pending_approval][:roles] || []}
            class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/10 text-violet-300 border border-violet-500/20"
          >
            <span class="text-zinc-400">{Map.get(role, :name) || Map.get(role, "name")}</span>
            <span class="text-violet-400/60">{Map.get(role, :role) || Map.get(role, "role")}</span>
          </span>
        </div>

        <%!-- Limit warning --%>
        <p
          :if={@card[:pending_approval][:limit_warning] == :depth}
          class="text-xs text-amber-400"
        >
          Approaching maximum nesting depth
        </p>
        <p
          :if={@card[:pending_approval][:limit_warning] == :agents}
          class="text-xs text-amber-400"
        >
          Approaching maximum agents per team
        </p>

        <%!-- Auto-approve checkbox --%>
        <label class="flex items-center gap-2 cursor-pointer select-none">
          <input
            type="checkbox"
            checked={@card[:pending_approval][:auto_approve_spawns]}
            phx-click="toggle_auto_approve_spawns"
            phx-value-agent={@card.name}
            phx-value-enabled={
              if @card[:pending_approval][:auto_approve_spawns], do: "false", else: "true"
            }
            class="rounded border-zinc-600 bg-zinc-800 text-violet-500 focus:ring-violet-500/50"
          />
          <span class="text-xs text-zinc-300">Auto-approve future spawns</span>
        </label>

        <%!-- Three-button row --%>
        <div class="flex items-center gap-1.5 mt-1">
          <button
            phx-click="approve_spawn"
            phx-value-gate_id={@card[:pending_approval][:gate_id]}
            phx-value-agent={@card.name}
            phx-value-context=""
            phx-disable-with="Approving..."
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-violet-600/80 hover:bg-violet-600 text-white border border-violet-500/50 transition-colors cursor-pointer"
          >
            Approve
          </button>
          <button
            phx-click={JS.toggle(to: "#spawn-approve-ctx-#{@card.name}")}
            type="button"
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-violet-800/60 hover:bg-violet-700/60 text-violet-200 border border-violet-600/30 transition-colors cursor-pointer"
          >
            Approve w/ Context
          </button>
          <button
            phx-click={JS.toggle(to: "#spawn-deny-ctx-#{@card.name}")}
            type="button"
            class="px-3 py-1.5 text-[11px] font-medium rounded bg-rose-900/40 hover:bg-rose-800/50 text-rose-300 border border-rose-700/30 transition-colors cursor-pointer"
          >
            Deny
          </button>
        </div>

        <%!-- Approve w/ Context form (hidden by default) --%>
        <form
          id={"spawn-approve-ctx-#{@card.name}"}
          phx-submit="approve_spawn"
          class="hidden flex-col gap-1.5 mt-1"
        >
          <textarea
            name="context"
            rows="2"
            placeholder="Optional context for the spawn..."
            class="w-full text-xs bg-zinc-900/60 border border-violet-500/30 rounded px-2 py-1.5 text-zinc-200 placeholder-zinc-500 resize-none focus:outline-none focus:border-violet-400/60"
          ></textarea>
          <input type="hidden" name="gate_id" value={@card[:pending_approval][:gate_id]} />
          <input type="hidden" name="agent" value={@card.name} />
          <button
            type="submit"
            phx-disable-with="Approving..."
            class="self-start px-3 py-1 text-[11px] font-medium rounded bg-violet-600/80 hover:bg-violet-600 text-white border border-violet-500/50 transition-colors cursor-pointer"
          >
            Send Approval
          </button>
        </form>

        <%!-- Deny form (hidden by default) --%>
        <form
          id={"spawn-deny-ctx-#{@card.name}"}
          phx-submit="deny_spawn"
          class="hidden flex-col gap-1.5 mt-1"
        >
          <textarea
            name="reason"
            rows="2"
            placeholder="Reason for denial (optional)..."
            class="w-full text-xs bg-zinc-900/60 border border-rose-700/30 rounded px-2 py-1.5 text-zinc-200 placeholder-zinc-500 resize-none focus:outline-none focus:border-rose-600/50"
          ></textarea>
          <input type="hidden" name="gate_id" value={@card[:pending_approval][:gate_id]} />
          <input type="hidden" name="agent" value={@card.name} />
          <button
            type="submit"
            phx-disable-with="Denying..."
            class="self-start px-3 py-1 text-[11px] font-medium rounded bg-rose-900/50 hover:bg-rose-800/60 text-rose-300 border border-rose-700/30 transition-colors cursor-pointer"
          >
            Confirm Denial
          </button>
        </form>
      </div>

      <%!-- AskUser panel — visible when status is :ask_user_pending and pending_questions is non-empty --%>
      <div
        :if={
          @card.status == :ask_user_pending &&
            @card[:pending_questions] != nil &&
            @card[:pending_questions] != []
        }
        class="border-t border-cyan-500/30 bg-cyan-950/20 px-4 py-3 flex flex-col gap-3"
      >
        <span class="text-[11px] font-semibold text-cyan-400">Question for you</span>

        <%!-- Sequential question list --%>
        <div :for={q <- @card[:pending_questions] || []} class="flex flex-col gap-1.5">
          <p class="text-xs text-zinc-300 leading-relaxed">{q.question}</p>
          <div class="flex flex-wrap gap-1.5">
            <%!--
              HEEx auto-escapes all `{...}` interpolations, so special characters
              in option values (quotes, angle brackets, etc.) are safe in both
              the button text and the phx-value-answer attribute.
            --%>
            <button
              :for={option <- q.options}
              phx-click="ask_user_answer"
              phx-value-question-id={q.question_id}
              phx-value-answer={option}
              phx-disable-with="Sending..."
              class="px-3 py-1.5 text-[11px] font-medium rounded bg-cyan-600/20 hover:bg-cyan-600/40 text-cyan-200 border border-cyan-500/30 transition-colors cursor-pointer"
            >
              {option}
            </button>
          </div>
        </div>

        <%!-- Single "Let the team decide" for the whole batch --%>
        <button
          phx-click="let_team_decide"
          phx-value-agent={@card.name}
          phx-disable-with="Deciding..."
          class="self-start px-3 py-1.5 text-[11px] font-medium rounded bg-zinc-700/60 hover:bg-zinc-600/60 text-zinc-300 border border-zinc-600/30 transition-colors cursor-pointer"
        >
          Let the team decide
        </button>
      </div>

      <%!-- Healing indicator panel — visible when status is :suspended_healing --%>
      <div
        :if={@card.status == :suspended_healing}
        class="border-t border-amber-500/30 bg-amber-950/20 px-4 py-3 flex flex-col gap-1.5"
      >
        <div class="flex items-center gap-2">
          <span class="text-[11px] font-semibold text-amber-400">Self-healing</span>
          <span class="text-[9px] font-mono text-amber-300/60">
            {healing_phase_label(@card[:healing_phase])}
          </span>
        </div>
        <div
          :if={@card[:healing_error_category]}
          class="text-[10px] text-amber-300/70"
        >
          {@card[:healing_error_category]}
        </div>
      </div>
    </div>
    """
  end

  # --- Card state animation class ---

  defp card_state_class(:thinking, _status), do: "card-breathing"
  defp card_state_class(:tool_call, _status), do: "card-tool-active"
  defp card_state_class(:streaming, _status), do: "card-streaming"
  defp card_state_class(_content_type, :paused), do: "agent-card-paused"
  defp card_state_class(_content_type, :blocked), do: "agent-card-blocked"
  defp card_state_class(_content_type, :approval_pending), do: "agent-card-approval"
  defp card_state_class(_content_type, :ask_user_pending), do: "agent-card-asking"
  defp card_state_class(_content_type, :awaiting_synthesis), do: "agent-card-awaiting-synthesis"
  defp card_state_class(_content_type, :suspended_healing), do: "agent-card-healing"
  defp card_state_class(_content_type, :error), do: "card-error"
  defp card_state_class(_content_type, :crashed), do: "card-error"
  defp card_state_class(_content_type, :recovering), do: "card-error"
  defp card_state_class(_content_type, :permanently_failed), do: "card-error"
  defp card_state_class(nil, :idle), do: "card-idle"
  defp card_state_class(_content_type, _status), do: nil

  # --- Card style (inline) — combines agent tint + tool-active state ---

  defp card_style(:tool_call, %{name: name}, _agent_color, _focused) when is_binary(name) do
    color = tool_config(name).color
    "border-color: #{color}; box-shadow: 0 0 10px #{hex_to_rgba(color, 0.1)};"
  end

  defp card_style(_content_type, _last_tool, _agent_color, true = _focused), do: nil

  defp card_style(_content_type, _last_tool, agent_color, _focused) do
    "background: linear-gradient(145deg, var(--surface-2), var(--surface-3)); border-color: #{agent_color}15;"
  end

  # --- Status helpers ---

  defp status_dot_class(:working), do: "bg-green-400 agent-dot-working"
  defp status_dot_class(:idle), do: "bg-zinc-500"
  defp status_dot_class(:blocked), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(:paused), do: "bg-blue-400 animate-pulse"
  defp status_dot_class(:error), do: "bg-red-400 agent-dot-error"
  defp status_dot_class(:waiting_permission), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(:approval_pending), do: "bg-violet-500 animate-pulse"
  defp status_dot_class(:ask_user_pending), do: "bg-cyan-500 animate-pulse"
  defp status_dot_class(:awaiting_synthesis), do: "bg-indigo-500 animate-pulse"
  defp status_dot_class(:suspended_healing), do: "bg-amber-400 animate-pulse"
  defp status_dot_class(:complete), do: "bg-emerald-400"
  defp status_dot_class(:crashed), do: "bg-red-500 animate-pulse"
  defp status_dot_class(:recovering), do: "bg-amber-400 animate-pulse"
  defp status_dot_class(:permanently_failed), do: "bg-red-600"
  defp status_dot_class(_), do: "bg-zinc-500"

  defp status_label(:working), do: "Working"
  defp status_label(:idle), do: "Idle"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:paused), do: "Paused"
  defp status_label(:error), do: "Error"
  defp status_label(:waiting_permission), do: "Waiting for permission"
  defp status_label(:approval_pending), do: "Awaiting approval"
  defp status_label(:ask_user_pending), do: "Waiting for you"
  defp status_label(:awaiting_synthesis), do: "Awaiting synthesis"
  defp status_label(:suspended_healing), do: "Healing..."
  defp status_label(:complete), do: "Complete"
  defp status_label(:crashed), do: "Crashed"
  defp status_label(:recovering), do: "Recovering"
  defp status_label(:permanently_failed), do: "Failed (max restarts)"
  defp status_label(_), do: "Unknown"

  defp status_pill_class(:working), do: "bg-green-500/20 text-green-400"
  defp status_pill_class(:idle), do: "bg-zinc-500/20 text-zinc-400"
  defp status_pill_class(:paused), do: "bg-blue-500/20 text-blue-400"
  defp status_pill_class(:error), do: "bg-red-500/20 text-red-400"
  defp status_pill_class(:crashed), do: "bg-red-500/20 text-red-400"
  defp status_pill_class(:approval_pending), do: "bg-amber-500/20 text-amber-400"
  defp status_pill_class(:ask_user_pending), do: "bg-amber-500/20 text-amber-400"
  defp status_pill_class(:awaiting_synthesis), do: "bg-indigo-500/20 text-indigo-400"
  defp status_pill_class(:waiting_permission), do: "bg-yellow-500/20 text-yellow-400"
  defp status_pill_class(:recovering), do: "bg-amber-500/20 text-amber-400"
  defp status_pill_class(:permanently_failed), do: "bg-red-500/20 text-red-400"
  defp status_pill_class(:suspended_healing), do: "bg-amber-500/20 text-amber-400"
  defp status_pill_class(:complete), do: "bg-emerald-500/20 text-emerald-400"
  defp status_pill_class(_), do: "bg-zinc-500/20 text-zinc-400"

  defp status_ring_class(:working), do: "ring-1 ring-green-500/40"
  defp status_ring_class(:error), do: "ring-2 ring-red-500 animate-pulse"
  defp status_ring_class(:crashed), do: "ring-2 ring-red-500 animate-pulse"
  defp status_ring_class(:ask_user_pending), do: "ring-2 ring-amber-400 animate-pulse"
  defp status_ring_class(:approval_pending), do: "ring-2 ring-violet-500/50 animate-pulse"
  defp status_ring_class(:waiting_permission), do: "ring-1 ring-yellow-500/50"
  defp status_ring_class(:awaiting_synthesis), do: "ring-1 ring-indigo-400/40"
  defp status_ring_class(:paused), do: "ring-1 ring-blue-500/30"
  defp status_ring_class(:permanently_failed), do: "ring-2 ring-red-600 animate-pulse"
  defp status_ring_class(:suspended_healing), do: "ring-2 ring-amber-400/50 animate-pulse"
  defp status_ring_class(_), do: nil

  # --- Healing phase helpers ---

  defp healing_phase_label(:diagnosing), do: "Diagnosing..."
  defp healing_phase_label(:fixing), do: "Applying fix..."
  defp healing_phase_label(:confirming), do: "Verifying..."
  defp healing_phase_label(_), do: "Diagnosing..."

  # --- Stuck warning helpers ---

  defp stuck_label(card) do
    idle_min = card[:stuck_idle_min] || 0

    cond do
      card[:stuck_escalated] ->
        "stuck #{idle_min}m — escalated"

      card[:stuck_nudge_count] ->
        "stuck #{idle_min}m — nudge #{card[:stuck_nudge_count]}/#{card[:stuck_max_nudges] || 2}"

      true ->
        "stuck #{idle_min}m"
    end
  end

  defp stuck_tooltip(card) do
    idle_min = card[:stuck_idle_min] || 0

    cond do
      card[:stuck_escalated] ->
        "Agent stuck for #{idle_min} minutes. Max nudges reached — escalated to team lead."

      card[:stuck_nudge_count] ->
        "Agent stuck for #{idle_min} minutes. Nudged #{card[:stuck_nudge_count]} of #{card[:stuck_max_nudges] || 2} times."

      true ->
        "Agent stuck for #{idle_min} minutes."
    end
  end

  # --- Conflict indicator helpers ---

  defp conflict_label(card) do
    case card[:conflict] do
      %{type: type} when type in [:file_conflict, :file] -> "file conflict"
      %{type: type} when type in [:approach_conflict, :approach] -> "approach conflict"
      %{type: type} when type in [:decision_conflict, :decision] -> "decision conflict"
      _ -> "conflict"
    end
  end

  defp conflict_tooltip(card) do
    case card[:conflict] do
      %{with: other, type: type} when is_binary(other) and other != "" ->
        type_str = type |> to_string() |> String.replace("_", " ")
        "#{type_str} with #{other}"

      _ ->
        "Conflict detected"
    end
  end

  # --- Capability bars ---

  defp capability_bars(assigns) do
    ~H"""
    <div :if={@caps != []} class="mt-1.5 flex items-center gap-3">
      <div
        :for={cap <- @caps}
        class="flex items-center gap-1 min-w-0"
        title={"#{cap.task_type}: #{Float.round(cap.score, 1)}"}
      >
        <span class="text-[9px] text-muted truncate w-8">
          {cap.task_type |> to_string() |> String.slice(0, 4)}
        </span>
        <div class="capability-bar w-10">
          <div
            class="capability-bar-fill"
            style={"width: #{cap_bar_width(cap.score)}%; background: var(--brand-hover);"}
          />
        </div>
      </div>
    </div>
    """
  end

  defp cap_bar_width(score) when score <= 0, do: 5
  defp cap_bar_width(score), do: min(round(score / 5.0 * 100), 100)

  # --- Tool lookup helpers ---

  defp tool_config(name) when is_binary(name),
    do: Map.get(@tool_config, name, @default_tool_config)

  defp tool_config(_), do: @default_tool_config

  # --- Formatting helpers ---

  defp role_matches_name?(role, name)
       when (is_atom(role) or is_binary(role)) and is_binary(name) do
    String.downcase(to_string(role)) == String.downcase(String.replace(name, "_", ""))
  end

  defp role_matches_name?(_, _), do: false

  defp format_role(role) when is_atom(role) or is_binary(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_role(_), do: "-"

  defp format_content(nil, _focused), do: ""

  defp format_content(content, focused) when is_binary(content) do
    trimmed = String.trim(content)
    if focused, do: trimmed, else: String.slice(trimmed, 0, 500)
  end

  defp format_content(_, _focused), do: ""

  defp render_card_markdown(""), do: ""

  defp render_card_markdown(content) when is_binary(content) do
    doc =
      MDEx.new()
      |> MDEx.Document.put_markdown(content)

    case MDEx.to_html(doc) do
      {:ok, html} ->
        Phoenix.HTML.raw(html)

      _ ->
        {:safe, escaped} = Phoenix.HTML.html_escape(content)
        Phoenix.HTML.raw("<p>#{escaped}</p>")
    end
  end

  defp render_card_markdown(_), do: ""

  # --- Model helpers ---

  defp format_model(nil), do: ""

  defp format_model(model) when is_binary(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.last()
    |> String.slice(0, 15)
  end

  defp format_model(_), do: ""

  defp short_team_label(team_id) when is_binary(team_id) do
    if String.length(team_id) > 8 do
      "sub-" <> String.slice(team_id, 0, 4)
    else
      team_id
    end
  end

  defp short_team_label(_), do: ""

  defp hex_to_rgba("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>, alpha) do
    "rgba(#{String.to_integer(r, 16)}, #{String.to_integer(g, 16)}, #{String.to_integer(b, 16)}, #{alpha})"
  end

  defp hex_to_rgba(color, _alpha), do: color

  # --- Spawn gate helpers ---

  # --- Test delegates for private helper functions ---
  # These thin wrappers allow unit tests to verify private logic
  # without live view rendering overhead.

  @doc false
  def status_dot_class_for_test(status), do: status_dot_class(status)

  @doc false
  def status_label_for_test(status), do: status_label(status)

  @doc false
  def card_state_class_for_test(content_type, status), do: card_state_class(content_type, status)
end
