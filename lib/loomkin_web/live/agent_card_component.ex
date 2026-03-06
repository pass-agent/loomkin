defmodule LoomkinWeb.AgentCardComponent do
  @moduledoc """
  Functional component that renders a single agent's workbench card in
  the mission control UI. Each agent gets one card that updates in-place,
  showing status, current activity, and action buttons.
  """

  use Phoenix.Component

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

  attr :card, :map, required: true
  attr :focused, :boolean, default: false
  attr :team_id, :string, required: true

  def agent_card(assigns) do
    ~H"""
    <div
      id={"agent-card-#{@card.name}"}
      phx-click="focus_card_agent"
      phx-value-agent={@card.name}
      class={[
        "group relative rounded-xl border p-4 animate-fade-in flex flex-col",
        if(@focused,
          do: "card-brand h-full overflow-hidden",
          else: "min-h-[140px] cursor-pointer bg-surface-1 border-subtle hover:bg-surface-2"
        )
      ]}
      style="transition: background var(--transition-base), border-color var(--transition-base);"
    >
      <%!-- Question overlay --%>
      <div
        :if={@card.pending_question}
        class="absolute inset-0 z-10 rounded-xl bg-gradient-to-br from-violet-900/30 to-purple-900/20 border border-violet-500/30 p-4 flex flex-col overflow-auto"
      >
        <div class="flex items-center gap-2 mb-3">
          <div class="w-6 h-6 rounded-lg bg-violet-500/20 flex items-center justify-center flex-shrink-0">
            <svg class="w-3.5 h-3.5 text-violet-400" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-8-3a1 1 0 00-.867.5 1 1 0 11-1.731-1A3 3 0 0113 8a3.001 3.001 0 01-2 2.83V11a1 1 0 11-2 0v-1a1 1 0 011-1 1 1 0 100-2zm0 8a1 1 0 100-2 1 1 0 000 2z"
                clip-rule="evenodd"
              />
            </svg>
          </div>
          <p class="text-xs font-semibold text-violet-300 truncate">
            {@card.pending_question.agent_name} needs your input
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
            class="px-3 py-1.5 text-xs font-medium text-violet-300 bg-violet-500/10 hover:bg-violet-500/25 border border-violet-500/30 hover:border-violet-400/50 rounded-lg transition-all duration-200 cursor-pointer"
          >
            {option}
          </button>
          <button
            phx-click="ask_user_answer"
            phx-value-question-id={@card.pending_question.question_id}
            phx-value-answer="__collective__"
            class="px-3 py-1.5 text-xs font-medium text-amber-300 bg-amber-500/10 hover:bg-amber-500/20 border border-amber-500/30 hover:border-amber-400/50 rounded-lg transition-all duration-200 cursor-pointer"
          >
            Let the collective decide
          </button>
        </div>
      </div>

      <%!-- Header: status dot, name, role badge, action buttons --%>
      <div class="flex items-center gap-2">
        <span class={["w-2 h-2 rounded-full flex-shrink-0", status_dot_class(@card.status)]}></span>
        <span
          class="text-sm font-medium truncate"
          style={"color: #{LoomkinWeb.AgentColors.agent_color(@card.name)}"}
        >
          {@card.name}
        </span>
        <span
          class="text-[10px] px-1.5 py-0.5 rounded font-medium text-muted"
          style="background: var(--brand-muted);"
        >
          {format_role(@card.role)}
        </span>

        <div class="flex-1"></div>

        <%!-- Action buttons (visible on hover) --%>
        <div
          class="flex items-center gap-0.5 opacity-0 group-hover:opacity-100"
          style="transition: opacity var(--transition-base);"
        >
          <%!-- Reply --%>
          <button
            phx-click="reply_to_card_agent"
            phx-value-agent={@card.name}
            phx-value-team-id={@team_id}
            title={"Reply to #{@card.name}"}
            class="text-muted hover:text-brand p-1 rounded-md hover:bg-surface-3 flex-shrink-0"
            style="transition: color var(--transition-base), background var(--transition-base);"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M7.707 3.293a1 1 0 010 1.414L5.414 7H11a7 7 0 017 7v2a1 1 0 11-2 0v-2a5 5 0 00-5-5H5.414l2.293 2.293a1 1 0 11-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <%!-- Pause (only when working) --%>
          <button
            :if={@card.status == :working}
            phx-click="pause_card_agent"
            phx-value-agent={@card.name}
            phx-value-team-id={@team_id}
            title={"Pause #{@card.name}"}
            class="text-muted hover:text-amber-400 p-1 rounded-md hover:bg-surface-3 flex-shrink-0"
            style="transition: color var(--transition-base), background var(--transition-base);"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zM7 8a1 1 0 012 0v4a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v4a1 1 0 102 0V8a1 1 0 00-1-1z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <%!-- Resume (only when paused) --%>
          <button
            :if={@card.status == :paused}
            phx-click="resume_card_agent"
            phx-value-agent={@card.name}
            phx-value-team-id={@team_id}
            title={"Resume #{@card.name}"}
            class="text-muted hover:text-green-400 p-1 rounded-md hover:bg-surface-3 flex-shrink-0"
            style="transition: color var(--transition-base), background var(--transition-base);"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path
                fill-rule="evenodd"
                d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <%!-- Steer (only when paused) --%>
          <button
            :if={@card.status == :paused}
            phx-click="steer_card_agent"
            phx-value-agent={@card.name}
            phx-value-team-id={@team_id}
            title={"Steer #{@card.name}"}
            class="text-muted hover:text-brand p-1 rounded-md hover:bg-surface-3 flex-shrink-0"
            style="transition: color var(--transition-base), background var(--transition-base);"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
            </svg>
          </button>
        </div>
      </div>

      <%!-- Content area --%>
      <div class={["mt-3 flex-1 min-h-0", @focused && "overflow-auto"]}>
        <%= case @card.content_type do %>
          <% :thinking -> %>
            <div
              class={[
                "text-xs leading-relaxed animate-pulse agent-card-content",
                !@focused && "line-clamp-4"
              ]}
              style="color: var(--text-secondary);"
            >
              {render_card_markdown(format_content(@card.latest_content, @focused))}
            </div>
          <% :last_thinking -> %>
            <div
              class={[
                "text-xs leading-relaxed opacity-50 agent-card-content",
                !@focused && "line-clamp-3"
              ]}
              style="color: var(--text-secondary);"
            >
              {render_card_markdown(format_content(@card.latest_content, @focused))}
            </div>
          <% :message -> %>
            <div
              class={[
                "text-xs leading-relaxed agent-card-content",
                !@focused && "line-clamp-4"
              ]}
              style="color: var(--text-secondary);"
            >
              {render_card_markdown(format_content(@card.latest_content, @focused))}
            </div>
          <% _ -> %>
            <%= if @card.status == :complete do %>
              <p class="text-xs italic" style="color: var(--color-emerald-400);">
                Orientation complete
              </p>
            <% else %>
              <p class="text-xs text-muted italic">idle</p>
            <% end %>
        <% end %>

        <%!-- Last tool (always visible as subtle footer) --%>
        <div :if={@card.last_tool} class="mt-1.5 flex items-center gap-1.5">
          <span
            class="text-[10px] opacity-60"
            style={"color: #{tool_config(@card.last_tool.name).color}"}
          >
            {tool_config(@card.last_tool.name).icon}
          </span>
          <span class="text-[10px] font-mono truncate text-muted opacity-60">
            {@card.last_tool.target || @card.last_tool.name}
          </span>
        </div>
      </div>

      <%!-- Footer: current task --%>
      <div
        :if={@card.current_task}
        class="mt-2 pt-2 flex items-center gap-2"
        style="border-top: 1px solid var(--border-subtle);"
      >
        <span class="text-[10px] text-muted uppercase tracking-wide flex-shrink-0">Current</span>
        <span class="text-xs truncate flex-1 font-mono" style="color: var(--text-secondary);">
          {@card.current_task}
        </span>
      </div>
    </div>
    """
  end

  # --- Status helpers ---

  defp status_dot_class(:working), do: "bg-green-400 agent-dot-working"
  defp status_dot_class(:idle), do: "bg-zinc-500"
  defp status_dot_class(:blocked), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(:paused), do: "bg-blue-400 animate-pulse"
  defp status_dot_class(:error), do: "bg-red-400 agent-dot-error"
  defp status_dot_class(:waiting_permission), do: "bg-amber-400 agent-dot-thinking"
  defp status_dot_class(:complete), do: "bg-emerald-400"
  defp status_dot_class(_), do: "bg-zinc-500"

  # --- Tool lookup helpers ---

  defp tool_config(name) when is_binary(name),
    do: Map.get(@tool_config, name, @default_tool_config)

  defp tool_config(_), do: @default_tool_config

  # --- Formatting helpers ---

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
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> Phoenix.HTML.raw("<p>#{Phoenix.HTML.html_escape(content)}</p>")
    end
  end

  defp render_card_markdown(_), do: ""
end
