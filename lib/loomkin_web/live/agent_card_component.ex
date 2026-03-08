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
       prev_focused: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    card = socket.assigns.card
    focused = socket.assigns.focused

    new_content = card && card.latest_content
    new_content_type = card && card.content_type
    old_content = socket.assigns.prev_content
    old_content_type = socket.assigns.prev_content_type
    old_focused = socket.assigns.prev_focused

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

        <%!-- Question overlay --%>
        <div
          :if={@card.pending_question}
          class="absolute inset-0 z-10 rounded-lg p-4 flex flex-col overflow-auto"
          style={"background: linear-gradient(135deg, #{@agent_color}18, #{@agent_color}08); border: 1px solid #{@agent_color}30;"}
        >
          <div class="flex items-center gap-2 mb-3">
            <div
              class="w-6 h-6 rounded flex items-center justify-center flex-shrink-0"
              style={"background: #{@agent_color}20;"}
            >
              <svg
                class="w-3.5 h-3.5"
                viewBox="0 0 20 20"
                fill="currentColor"
                style={"color: #{@agent_color};"}
              >
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-8-3a1 1 0 00-.867.5 1 1 0 11-1.731-1A3 3 0 0113 8a3.001 3.001 0 01-2 2.83V11a1 1 0 11-2 0v-1a1 1 0 011-1 1 1 0 100-2zm0 8a1 1 0 100-2 1 1 0 000 2z"
                  clip-rule="evenodd"
                />
              </svg>
            </div>
            <p class="text-xs font-semibold truncate" style={"color: #{@agent_color};"}>
              {@card.pending_question.agent_name} needs input
            </p>
          </div>

          <p class="text-sm text-gray-200 mb-3 leading-relaxed line-clamp-2">
            {@card.pending_question.question}
          </p>

          <div class="flex flex-wrap gap-1.5 mt-auto">
            <button
              :for={option <- @card.pending_question.options}
              phx-click="ask_user_answer"
              phx-value-question-id={@card.pending_question.question_id}
              phx-value-answer={option}
              class="px-3 py-1.5 text-xs font-medium rounded transition-all duration-200 cursor-pointer"
              style={"color: #{@agent_color}; background: #{@agent_color}10; border: 1px solid #{@agent_color}30;"}
            >
              {option}
            </button>
            <button
              phx-click="ask_user_answer"
              phx-value-question-id={@card.pending_question.question_id}
              phx-value-answer="__collective__"
              class="px-3 py-1.5 text-xs font-medium text-amber-300 bg-amber-500/10 border border-amber-500/30 rounded transition-all duration-200 cursor-pointer"
            >
              Collective
            </button>
          </div>
        </div>

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
          team_id={@team_id}
          agent_name={@card.name}
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
                  "text-xs leading-relaxed opacity-30 agent-card-content pl-2",
                  !@focused && "line-clamp-3"
                ]}
                style={"color: var(--text-muted); border-left: 1px solid #{@agent_color}15;"}
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
              <%= if @card.status == :complete do %>
                <div class="flex items-center gap-2 text-xs">
                  <div class="h-px flex-1" style={"background: #{@agent_color}15;"} />
                  <span style={"color: #{@agent_color}80;"}>complete</span>
                  <div class="h-px flex-1" style={"background: #{@agent_color}15;"} />
                </div>
              <% else %>
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
    </div>
    """
  end

  # --- Card state animation class ---

  defp card_state_class(:thinking, _status), do: "card-breathing"
  defp card_state_class(:tool_call, _status), do: "card-tool-active"
  defp card_state_class(:streaming, _status), do: "card-streaming"
  defp card_state_class(_content_type, :paused), do: "agent-card-paused"
  defp card_state_class(_content_type, :blocked), do: "agent-card-blocked"
  defp card_state_class(_content_type, :approval_pending), do: "agent-card-blocked"
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
  defp status_dot_class(:approval_pending), do: "bg-amber-400 agent-dot-thinking"
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
  defp status_label(:complete), do: "Complete"
  defp status_label(:crashed), do: "Crashed"
  defp status_label(:recovering), do: "Recovering"
  defp status_label(:permanently_failed), do: "Failed (max restarts)"
  defp status_label(_), do: "Unknown"

  # --- Capability bars ---

  defp capability_bars(assigns) do
    caps =
      Loomkin.Teams.Capabilities.get_capabilities(assigns.team_id, assigns.agent_name)
      |> Enum.take(3)

    assigns = assign(assigns, :caps, caps)

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
      MDEx.new(render: [unsafe_: true])
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
end
