defmodule LoomkinWeb.WorkSurfaceSidebarComponent do
  @moduledoc """
  Collapsible left-rail sidebar showing live work surfaces.

  Provides at-a-glance navigation for:
  - Active files being worked on by agents (file reads/writes/edits)
  - In-progress tasks with assigned agents
  - Team hierarchy with agent counts
  - Quick workspace actions (files, kin panel, debug)

  All interactive events are forwarded to the parent WorkspaceLive via
  `send(self(), {:sidebar_event, event, params})`.
  """

  use LoomkinWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:collapsed, fn -> false end)
      |> compute_work_surfaces()

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, collapsed: !socket.assigns.collapsed)}
  end

  def handle_event("select_surface", %{"type" => "file", "path" => path}, socket) do
    send(self(), {:sidebar_event, "select_file", %{"path" => path}})
    {:noreply, socket}
  end

  def handle_event("select_surface", %{"type" => "task", "task-id" => task_id}, socket) do
    send(self(), {:sidebar_event, "focus_task", %{"task_id" => task_id}})
    {:noreply, socket}
  end

  def handle_event("select_surface", %{"type" => "agent", "agent" => agent_name}, socket) do
    send(self(), {:sidebar_event, "focus_agent", %{"agent" => agent_name}})
    {:noreply, socket}
  end

  def handle_event("switch_team", %{"team-id" => team_id}, socket) do
    send(self(), {:sidebar_event, "switch_team", %{"team-id" => team_id}})
    {:noreply, socket}
  end

  def handle_event("sidebar_action", %{"action" => action}, socket) do
    send(self(), {:sidebar_event, "action", %{"action" => action}})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav
      id="work-surface-sidebar"
      class={sidebar_class(@collapsed)}
      aria-label="Work surfaces"
    >
      <%!-- Toggle button — always visible --%>
      <button
        phx-click="toggle_sidebar"
        phx-target={@myself}
        class="sidebar-toggle"
        aria-label={if @collapsed, do: "Expand sidebar", else: "Collapse sidebar"}
      >
        <svg
          class={[
            "w-3.5 h-3.5 text-muted transition-transform duration-200",
            @collapsed && "rotate-180"
          ]}
          viewBox="0 0 20 20"
          fill="currentColor"
        >
          <path
            fill-rule="evenodd"
            d="M12.79 5.23a.75.75 0 01-.02 1.06L8.832 10l3.938 3.71a.75.75 0 11-1.04 1.08l-4.5-4.25a.75.75 0 010-1.08l4.5-4.25a.75.75 0 011.06.02z"
            clip-rule="evenodd"
          />
        </svg>
      </button>

      <%= if @collapsed do %>
        {render_collapsed(assigns)}
      <% else %>
        {render_expanded(assigns)}
      <% end %>
    </nav>
    """
  end

  # ── Collapsed: icon-only vertical strip ──

  defp render_collapsed(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1 py-2">
      <%!-- Active files indicator --%>
      <button
        :if={@active_files != []}
        phx-click="sidebar_action"
        phx-value-action="toggle_files"
        phx-target={@myself}
        class="sidebar-icon-btn relative"
        title={"#{length(@active_files)} active files"}
      >
        <.icon name="hero-document-text-mini" class="w-4 h-4" />
        <span class="absolute -top-0.5 -right-0.5 w-3.5 h-3.5 rounded-full bg-brand text-[8px] font-bold text-white flex items-center justify-center">
          {length(@active_files)}
        </span>
      </button>

      <%!-- Active tasks indicator --%>
      <button
        :if={@active_tasks != []}
        phx-click="sidebar_action"
        phx-value-action="toggle_tasks"
        phx-target={@myself}
        class="sidebar-icon-btn relative"
        title={"#{length(@active_tasks)} active tasks"}
      >
        <.icon name="hero-clipboard-document-list-mini" class="w-4 h-4" />
        <span class="absolute -top-0.5 -right-0.5 w-3.5 h-3.5 rounded-full bg-emerald-500 text-[8px] font-bold text-white flex items-center justify-center">
          {length(@active_tasks)}
        </span>
      </button>

      <%!-- Team tree --%>
      <button
        :if={@team_tree != %{}}
        phx-click="sidebar_action"
        phx-value-action="toggle_teams"
        phx-target={@myself}
        class="sidebar-icon-btn"
        title="Team hierarchy"
      >
        <.icon name="hero-squares-2x2-mini" class="w-4 h-4" />
      </button>

      <div class="flex-1" />

      <%!-- Quick actions --%>
      <button
        phx-click="sidebar_action"
        phx-value-action="toggle_files"
        phx-target={@myself}
        class="sidebar-icon-btn"
        title="Files & diffs"
      >
        <.icon name="hero-folder-open-mini" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  # ── Expanded: full sidebar with sections ──

  defp render_expanded(assigns) do
    ~H"""
    <div class="flex flex-col h-full min-h-0 overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center gap-2 px-3 py-2.5 flex-shrink-0 border-b border-border-subtle">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted">
          Work Surfaces
        </span>
        <div class="flex-1" />
      </div>

      <div class="flex-1 overflow-y-auto min-h-0 sidebar-scroll">
        <%!-- Active Files Section --%>
        {render_active_files(assigns)}

        <%!-- Active Tasks Section --%>
        {render_active_tasks(assigns)}

        <%!-- Team Hierarchy Section --%>
        {render_team_section(assigns)}
      </div>

      <%!-- Quick Actions Footer --%>
      <div class="flex-shrink-0 border-t border-border-subtle px-2 py-2">
        <div class="flex items-center gap-1">
          <button
            phx-click="sidebar_action"
            phx-value-action="toggle_files"
            phx-target={@myself}
            class="sidebar-footer-btn"
            title="Files & diffs"
          >
            <.icon name="hero-folder-open-mini" class="w-3.5 h-3.5" />
          </button>
          <button
            phx-click="sidebar_action"
            phx-value-action="open_kin"
            phx-target={@myself}
            class="sidebar-footer-btn"
            title="Manage kin"
          >
            <.icon name="hero-user-group-mini" class="w-3.5 h-3.5" />
          </button>
          <button
            phx-click="sidebar_action"
            phx-value-action="command_palette"
            phx-target={@myself}
            class="sidebar-footer-btn"
            title="Command palette (⌘K)"
          >
            <.icon name="hero-command-line-mini" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Active Files ──

  defp render_active_files(assigns) do
    ~H"""
    <div :if={@active_files != []} class="sidebar-section">
      <div class="sidebar-section-header">
        <span class="flex items-center gap-1.5">
          <span class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
          <span class="sidebar-section-label">Active Files</span>
        </span>
        <span class="sidebar-section-count">{length(@active_files)}</span>
      </div>
      <div class="space-y-0.5">
        <button
          :for={file <- @active_files}
          phx-click="select_surface"
          phx-value-type="file"
          phx-value-path={file.path}
          phx-target={@myself}
          class="sidebar-item group"
          title={file.path}
        >
          <span class="sidebar-item-icon">{file_icon(file.action)}</span>
          <span class="sidebar-item-label truncate">{Path.basename(file.path)}</span>
          <span
            :if={file.agent}
            class="sidebar-item-agent"
            style={"color: #{LoomkinWeb.AgentColors.agent_color(file.agent)}80;"}
          >
            {file.agent}
          </span>
        </button>
      </div>
    </div>
    """
  end

  # ── Active Tasks ──

  defp render_active_tasks(assigns) do
    ~H"""
    <div :if={@active_tasks != []} class="sidebar-section">
      <div class="sidebar-section-header">
        <span class="flex items-center gap-1.5">
          <span class="w-1.5 h-1.5 rounded-full bg-emerald-400" />
          <span class="sidebar-section-label">Tasks</span>
        </span>
        <span class="sidebar-section-count">{length(@active_tasks)}</span>
      </div>
      <div class="space-y-0.5">
        <button
          :for={task <- Enum.take(@active_tasks, 10)}
          phx-click="select_surface"
          phx-value-type="agent"
          phx-value-agent={task.agent}
          phx-target={@myself}
          class="sidebar-item group"
          title={task.title}
        >
          <span class={["sidebar-task-dot", task_status_dot(task.status)]} />
          <span class="sidebar-item-label truncate">{truncate_title(task.title)}</span>
          <span
            :if={task.agent}
            class="sidebar-item-agent"
            style={"color: #{LoomkinWeb.AgentColors.agent_color(task.agent)}80;"}
          >
            {task.agent}
          </span>
        </button>
      </div>
    </div>
    """
  end

  # ── Team Hierarchy ──

  defp render_team_section(assigns) do
    ~H"""
    <div :if={@team_tree != %{} && @root_team_id} class="sidebar-section">
      <div class="sidebar-section-header">
        <span class="sidebar-section-label">Teams</span>
      </div>
      {render_team_node(assigns, @root_team_id, 0)}
    </div>
    """
  end

  defp render_team_node(assigns, team_id, depth) do
    children = Map.get(assigns.team_tree, team_id, [])
    team_name = Map.get(assigns.team_names, team_id)
    agent_count = Map.get(assigns.agent_counts, team_id, 0)
    is_active = team_id == assigns.active_team_id

    assigns =
      assigns
      |> assign(:node_team_id, team_id)
      |> assign(:node_children, children)
      |> assign(:node_name, team_name)
      |> assign(:node_agent_count, agent_count)
      |> assign(:node_is_active, is_active)
      |> assign(:node_depth, depth)

    ~H"""
    <div style={"padding-left: #{@node_depth * 12}px;"}>
      <button
        phx-click="switch_team"
        phx-value-team-id={@node_team_id}
        phx-target={@myself}
        class={[
          "sidebar-item group w-full",
          @node_is_active && "sidebar-item-active"
        ]}
      >
        <span :if={@node_children != []} class="text-[9px] text-muted/40">▾</span>
        <span class="sidebar-item-label truncate">
          {team_display_name(@node_name, @node_team_id)}
        </span>
        <span class="sidebar-section-count ml-auto">{@node_agent_count}</span>
      </button>
      <div :for={child_id <- @node_children}>
        {render_team_node(assigns, child_id, @node_depth + 1)}
      </div>
    </div>
    """
  end

  # ── Data computation ──

  defp compute_work_surfaces(socket) do
    agent_cards = socket.assigns[:agent_cards] || %{}
    cached_tasks = socket.assigns[:cached_tasks] || []
    cached_agents = socket.assigns[:cached_agents] || []

    # Extract active files from agent card tool activity
    active_files = extract_active_files(agent_cards)

    # Extract active tasks from cached tasks
    active_tasks = extract_active_tasks(cached_tasks, cached_agents)

    # Compute agent counts per team
    agent_counts = compute_agent_counts(cached_agents)

    assign(socket,
      active_files: active_files,
      active_tasks: active_tasks,
      agent_counts: agent_counts
    )
  end

  defp extract_active_files(agent_cards) do
    agent_cards
    |> Enum.flat_map(fn {agent_name, card} ->
      case card do
        %{last_tool: %{name: tool_name, target: path}}
        when is_binary(path) and tool_name in ["file_read", "file_write", "file_edit"] ->
          action =
            case tool_name do
              "file_read" -> :read
              "file_write" -> :write
              "file_edit" -> :edit
              _ -> :unknown
            end

          [%{path: path, agent: agent_name, action: action, tool: tool_name}]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.path)
    |> Enum.take(15)
  end

  defp extract_active_tasks(cached_tasks, cached_agents) do
    # Build a map of agent names to their current tasks
    agent_task_map =
      Enum.reduce(cached_agents, %{}, fn agent, acc ->
        if agent[:current_task] do
          Map.put(acc, agent.name, agent.current_task)
        else
          acc
        end
      end)

    # Get in-progress tasks from the task list
    in_progress =
      cached_tasks
      |> Enum.filter(fn task ->
        task.status in [:in_progress, :assigned, :pending]
      end)
      |> Enum.map(fn task ->
        agent =
          cond do
            task[:owner] -> task.owner
            task[:assigned_to] -> task.assigned_to
            true -> nil
          end

        %{
          id: task.id,
          title: task.title || "Untitled task",
          status: task.status,
          agent: agent
        }
      end)
      |> Enum.take(10)

    # If no task list but agents have current_task, show those
    if in_progress == [] do
      agent_task_map
      |> Enum.map(fn {agent_name, task_desc} ->
        %{
          id: "agent-task-#{agent_name}",
          title: task_desc,
          status: :in_progress,
          agent: agent_name
        }
      end)
      |> Enum.take(10)
    else
      in_progress
    end
  end

  defp compute_agent_counts(cached_agents) do
    Enum.group_by(cached_agents, & &1.team_id)
    |> Map.new(fn {team_id, agents} -> {team_id, length(agents)} end)
  end

  # ── Helpers ──

  defp sidebar_class(true), do: "work-surface-sidebar work-surface-sidebar-collapsed"
  defp sidebar_class(false), do: "work-surface-sidebar work-surface-sidebar-expanded"

  defp file_icon(:read), do: "📄"
  defp file_icon(:write), do: "✍️"
  defp file_icon(:edit), do: "✎"
  defp file_icon(_), do: "📄"

  defp task_status_dot(:in_progress), do: "bg-emerald-400 animate-pulse"
  defp task_status_dot(:assigned), do: "bg-blue-400"
  defp task_status_dot(:pending), do: "bg-zinc-400"
  defp task_status_dot(_), do: "bg-zinc-500"

  defp truncate_title(nil), do: "—"

  defp truncate_title(title) when is_binary(title) do
    if String.length(title) > 40 do
      String.slice(title, 0, 37) <> "..."
    else
      title
    end
  end

  defp truncate_title(other), do: to_string(other)

  defp team_display_name(nil, team_id) do
    if is_binary(team_id) do
      String.slice(team_id, 0, 8) <> "..."
    else
      "Team"
    end
  end

  defp team_display_name(name, _team_id) when is_binary(name), do: name
  defp team_display_name(_, _), do: "Team"
end
