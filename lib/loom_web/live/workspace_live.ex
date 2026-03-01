defmodule LoomWeb.WorkspaceLive do
  use LoomWeb, :live_view

  alias Loom.Session
  alias Loom.Session.Manager

  require Logger

  @default_model "anthropic:claude-sonnet-4-6"

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        messages: [],
        status: :idle,
        active_tab: :files,
        model: @default_model,
        input_text: "",
        current_tool: nil,
        current_tool_name: nil,
        file_tree_version: 0,
        selected_file: nil,
        file_content: nil,
        diffs: [],
        shell_commands: [],
        permission_request: nil,
        page_title: "Loom Workspace",
        team_id: params["team_id"],
        team_sub_tab: :activity
      )

    case socket.assigns.live_action do
      :index ->
        session_id = Ecto.UUID.generate()
        {:ok, start_and_subscribe(socket, session_id)}

      :show ->
        session_id = params["session_id"]
        {:ok, start_and_subscribe(socket, session_id)}
    end
  end

  defp start_and_subscribe(socket, session_id) do
    # Use full lead tool set — every session is a team-capable lead agent
    tools = Loom.Tools.Registry.for_lead()
    project_path = File.cwd!()

    {:ok, _pid} =
      Manager.start_session(
        session_id: session_id,
        model: socket.assigns.model,
        project_path: project_path,
        tools: tools,
        auto_approve: false
      )

    if connected?(socket) do
      Session.subscribe(session_id)
      Phoenix.PubSub.subscribe(Loom.PubSub, "telemetry:updates")
      ensure_index_started(project_path)

      team_id = socket.assigns[:team_id]

      if team_id do
        Phoenix.PubSub.subscribe(Loom.PubSub, "team:#{team_id}")
        Phoenix.PubSub.subscribe(Loom.PubSub, "team:#{team_id}:tasks")
      end
    end

    # Load existing history
    messages =
      case Session.get_history(session_id) do
        {:ok, msgs} -> msgs
        _ -> []
      end

    session_metrics = Loom.Telemetry.Metrics.session_metrics(session_id)

    assign(socket,
      session_id: session_id,
      project_path: project_path,
      messages: messages,
      session_cost: session_metrics.cost_usd,
      session_tokens: session_metrics.prompt_tokens + session_metrics.completion_tokens,
      page_title: "Loom - #{short_id(session_id)}"
    )
  end

  # --- Events ---

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    session_id = socket.assigns.session_id
    # Send async to avoid blocking the LiveView process
    task = Task.async(fn -> Session.send_message(session_id, String.trim(text)) end)

    {:noreply,
     socket
     |> assign(input_text: "", async_task: task)
     |> push_event("clear-input", %{})}
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("change_model", %{"model" => model}, socket) do
    Session.update_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{id}")}
  end

  def handle_event("deselect_file", _params, socket) do
    {:noreply, assign(socket, selected_file: nil, file_content: nil)}
  end


  def handle_event("permission_response", %{"action" => _action}, socket) do
    # Placeholder for when permissions are wired up
    {:noreply, socket}
  end

  def handle_event("switch_sub_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, team_sub_tab: String.to_existing_atom(tab))}
  end

  # --- PubSub Info ---

  def handle_info({:new_message, _session_id, msg}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg])}
  end

  def handle_info({:session_status, _session_id, status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  def handle_info({:tool_executing, _session_id, tool_name}, socket) do
    {:noreply, assign(socket, current_tool: tool_name, current_tool_name: tool_name)}
  end

  def handle_info({:tool_complete, _session_id, tool_name, result}, socket) do
    socket = assign(socket, current_tool: nil)

    # Bump file tree version when file-modifying tools complete
    socket =
      if tool_name in ["file_edit", "file_write", "file_delete"] do
        assign(socket, file_tree_version: socket.assigns.file_tree_version + 1)
      else
        socket
      end

    socket =
      cond do
        tool_name in ["file_edit", "file_write"] ->
          diff = LoomWeb.DiffComponent.parse_edit_result(result)
          assign(socket, diffs: socket.assigns.diffs ++ [diff])

        tool_name == "shell" ->
          cmd = parse_shell_result(result)
          assign(socket, shell_commands: socket.assigns.shell_commands ++ [cmd])

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:permission_request, _session_id, tool_name, tool_path}, socket) do
    {:noreply, assign(socket, permission_request: %{tool_name: tool_name, tool_path: tool_path})}
  end

  def handle_info({:team_available, _session_id, team_id}, socket) do
    # Auto-subscribe to backing team events when the team is created
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loom.PubSub, "team:#{team_id}")
      Phoenix.PubSub.subscribe(Loom.PubSub, "team:#{team_id}:tasks")
    end

    {:noreply, assign(socket, team_id: team_id)}
  end

  def handle_info({:architect_phase, _phase}, socket) do
    {:noreply, socket}
  end

  def handle_info({:architect_plan, _session_id, _plan_data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:architect_step, _session_id, _step}, socket) do
    {:noreply, socket}
  end

  def handle_info({:select_file, path}, socket) do
    abs_path = Path.join(socket.assigns.project_path, path)

    file_content =
      case File.read(abs_path) do
        {:ok, content} -> content
        {:error, _} -> "Error: could not read file"
      end

    {:noreply, assign(socket, selected_file: path, file_content: file_content)}
  end

  # Messages from child components
  def handle_info({:change_model, model}, socket) do
    Session.update_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, model: model)}
  end

  def handle_info(:new_session, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_info({:select_session, session_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{session_id}")}
  end

  def handle_info({:permission_response, _action, _tool_name, _tool_path}, socket) do
    # Permission responses are handled by the Architect pipeline directly.
    {:noreply, assign(socket, permission_request: nil)}
  end

  # Team PubSub events -- forward to team components via send_update
  def handle_info({:agent_status, _agent_name, _status}, socket) do
    if socket.assigns[:team_id] do
      send_update(LoomWeb.TeamDashboardComponent, id: "team-dashboard", team_id: socket.assigns.team_id)
      send_update(LoomWeb.TeamActivityComponent, id: "team-activity", team_id: socket.assigns.team_id)
    end

    {:noreply, socket}
  end

  def handle_info({:task_assigned, _task_id, _agent_name} = _msg, socket) do
    if socket.assigns[:team_id] do
      send_update(LoomWeb.TeamDashboardComponent, id: "team-dashboard", team_id: socket.assigns.team_id)
    end

    {:noreply, socket}
  end

  def handle_info({:task_completed, _task_id, _agent_name, _result} = _msg, socket) do
    if socket.assigns[:team_id] do
      send_update(LoomWeb.TeamDashboardComponent, id: "team-dashboard", team_id: socket.assigns.team_id)
    end

    {:noreply, socket}
  end

  def handle_info({:team_dissolved, _team_id}, socket) do
    {:noreply, assign(socket, team_id: nil, active_tab: :files)}
  end

  # Telemetry metrics update
  def handle_info(:metrics_updated, socket) do
    metrics = Loom.Telemetry.Metrics.session_metrics(socket.assigns.session_id)

    {:noreply,
     assign(socket,
       session_cost: metrics.cost_usd,
       session_tokens: metrics.prompt_tokens + metrics.completion_tokens
     )}
  end

  # Handle async task completion
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _response} ->
        Logger.debug("[WorkspaceLive] Async task completed successfully")

      {:error, reason} ->
        Logger.error("[WorkspaceLive] Async task returned error: #{inspect(reason)}")

      other ->
        Logger.warning("[WorkspaceLive] Async task returned unexpected result: #{inspect(other)}")
    end

    {:noreply, assign(socket, async_task: nil)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if reason != :normal do
      Logger.error("[WorkspaceLive] Async task crashed: #{inspect(reason)}")
    end

    {:noreply, assign(socket, async_task: nil)}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-950 text-gray-100">
      <%!-- Permission modal overlay --%>
      <.live_component
        :if={@permission_request}
        module={LoomWeb.PermissionComponent}
        id="permission-modal"
        tool_name={@permission_request.tool_name}
        tool_path={@permission_request.tool_path}
      />

      <%!-- ── Header ── --%>
      <header class="flex items-center justify-between px-6 py-3 bg-gray-900 border-b border-gray-800 header-glow">
        <div class="flex items-center gap-4">
          <%!-- Branding --%>
          <div class="flex items-center gap-2">
            <span class="text-base opacity-70">&#129525;</span>
            <span class="text-xl font-bold bg-gradient-to-r from-violet-400 to-purple-400 bg-clip-text text-transparent tracking-tight">
              Loom
            </span>
          </div>

          <%!-- Model selector --%>
          <.live_component module={LoomWeb.ModelSelectorComponent} id="model-selector" model={@model} />
        </div>

        <div class="flex items-center gap-3">
          <%!-- Cost pill --%>
          <a
            href="/dashboard"
            class="flex items-center gap-1.5 bg-gray-800/60 hover:bg-gray-800 rounded-full px-3 py-1.5 transition-colors group"
          >
            <.icon name="hero-sparkles-mini" class="w-3.5 h-3.5 text-violet-400 group-hover:text-violet-300" />
            <span class="text-xs font-mono text-gray-300">${format_cost(@session_cost)}</span>
            <span class="text-[10px] text-gray-500 font-mono">{format_tokens(@session_tokens)} tok</span>
          </a>

          <%!-- Session switcher --%>
          <.live_component module={LoomWeb.SessionSwitcherComponent} id="session-switcher" session_id={@session_id} />

          <%!-- Status indicator --%>
          <div class={"flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-medium transition-all duration-300 " <> status_pill_class(@status)}>
            <span class={status_dot_class(@status)} />
            {status_label(@status, @current_tool_name)}
          </div>
        </div>
      </header>

      <%!-- ── Main Content ── --%>
      <div class="flex flex-1 overflow-hidden">
        <%!-- Left: Chat + Input --%>
        <div class="flex-1 flex flex-col min-w-0">
          <.live_component
            module={LoomWeb.ChatComponent}
            id="chat"
            messages={@messages}
            status={@status}
            current_tool={@current_tool}
          />

          <%!-- Input area --%>
          <form phx-submit="send_message" class="p-4 border-t border-gray-800 bg-gray-900/80">
            <div class="flex gap-3 items-end">
              <div class="flex-1 relative">
                <textarea
                  name="text"
                  rows="1"
                  placeholder="What should we work on?"
                  class="w-full bg-gray-800/60 border border-gray-700/50 rounded-xl px-4 py-3 text-sm text-gray-100 resize-none placeholder-gray-500 placeholder:italic focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-500/50 transition-shadow"
                  phx-hook="ShiftEnterSubmit"
                  id="message-input"
                ><%= @input_text %></textarea>
              </div>
              <button
                type="submit"
                class={"flex items-center justify-center w-10 h-10 rounded-xl transition-all duration-200 " <>
                  if(@status == :idle, do: "bg-violet-600 hover:bg-violet-500 text-white send-btn-ready", else: "bg-gray-800 text-gray-600 cursor-not-allowed")}
                disabled={@status != :idle}
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5" />
                </svg>
              </button>
            </div>
            <p class="text-[10px] text-gray-600 mt-1.5 pl-1">
              <kbd class="px-1 py-0.5 bg-gray-800/60 rounded text-gray-500 font-mono text-[9px]">Shift+Enter</kbd>
              for new line
            </p>
          </form>
        </div>

        <%!-- Right: Sidebar --%>
        <div class="w-96 border-l border-gray-800 flex flex-col bg-gray-900/50">
          <%!-- Sidebar tab bar --%>
          <div class="flex items-center gap-1 px-3 py-2 border-b border-gray-800 bg-gray-900/80">
            <button
              :for={tab <- [:files, :diff, :terminal, :graph, :team]}
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={"flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all duration-200 " <>
                if(@active_tab == tab,
                  do: "bg-gray-800 text-violet-400",
                  else: "text-gray-500 hover:text-gray-300 hover:bg-gray-800/40")}
            >
              <span class="text-sm">{tab_icon(tab)}</span>
              {tab_label(tab)}
            </button>
          </div>

          <%!-- Sidebar content with transition --%>
          <div class="flex-1 overflow-auto p-4 tab-content-enter" phx-hook="TabTransition" id={"tab-content-#{@active_tab}"}>
            {render_tab(@active_tab, assigns)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp status_pill_class(:idle), do: "bg-green-900/30 text-green-400"
  defp status_pill_class(:thinking), do: "bg-violet-900/30 text-violet-400"
  defp status_pill_class(:executing_tool), do: "bg-blue-900/30 text-blue-400"
  defp status_pill_class(_), do: "bg-gray-800/60 text-gray-400"

  defp status_dot_class(:idle), do: "w-2 h-2 rounded-full bg-green-400 status-dot-idle"
  defp status_dot_class(:thinking), do: "w-2 h-2 rounded-full bg-violet-400 status-dot-thinking"
  defp status_dot_class(:executing_tool), do: "w-2 h-2 rounded-full bg-blue-400 animate-spin"
  defp status_dot_class(_), do: "w-2 h-2 rounded-full bg-gray-500"

  defp status_label(:idle, _tool), do: "Ready"
  defp status_label(:thinking, _tool), do: "Thinking..."
  defp status_label(:executing_tool, nil), do: "Running tool..."
  defp status_label(:executing_tool, tool_name), do: tool_name
  defp status_label(status, _tool), do: to_string(status)

  defp tab_icon(:files), do: raw("<span class=\"hero-folder-mini inline-block w-3.5 h-3.5\"></span>")
  defp tab_icon(:diff), do: raw("<span class=\"hero-code-bracket-mini inline-block w-3.5 h-3.5\"></span>")
  defp tab_icon(:terminal), do: raw("<span class=\"hero-command-line-mini inline-block w-3.5 h-3.5\"></span>")
  defp tab_icon(:graph), do: raw("<span class=\"hero-share-mini inline-block w-3.5 h-3.5\"></span>")
  defp tab_icon(:team), do: raw("<span class=\"hero-user-group-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_label(:files), do: "Files"
  defp tab_label(:diff), do: "Diff"
  defp tab_label(:terminal), do: "Terminal"
  defp tab_label(:graph), do: "Graph"
  defp tab_label(:team), do: "Team"

  defp render_tab(:files, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class={if @selected_file, do: "h-1/2 overflow-auto", else: "flex-1"}>
        <.live_component
          module={LoomWeb.FileTreeComponent}
          id="file-tree"
          project_path={assigns[:project_path] || File.cwd!()}
          session_id={@session_id}
          version={@file_tree_version}
        />
      </div>
      <div :if={@selected_file} class="h-1/2 border-t border-gray-800 flex flex-col animate-fade-in">
        <div class="flex items-center justify-between px-3 py-2 bg-gray-900/80 border-b border-gray-800">
          <div class="flex items-center gap-2 truncate">
            <.icon name="hero-document-text-mini" class="w-3.5 h-3.5 text-violet-400 flex-shrink-0" />
            <span class="text-xs text-violet-400 font-mono truncate">{@selected_file}</span>
          </div>
          <button
            phx-click="deselect_file"
            class="text-gray-500 hover:text-gray-300 text-xs p-1 rounded hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
          </button>
        </div>
        <pre class="flex-1 overflow-auto p-3 text-xs font-mono text-gray-300 whitespace-pre">{@file_content}</pre>
      </div>
    </div>
    """
  end

  defp render_tab(:diff, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.DiffComponent}
      id="diff-viewer"
      diffs={@diffs}
    />
    """
  end

  defp render_tab(:terminal, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.TerminalComponent}
      id="terminal"
      commands={@shell_commands}
    />
    """
  end

  defp render_tab(:graph, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.DecisionGraphComponent}
      id="decision-graph"
      session_id={@session_id}
    />
    """
  end

  defp render_tab(:team, assigns) do
    ~H"""
    <div class="flex flex-col h-full gap-3">
      <.live_component
        module={LoomWeb.TeamDashboardComponent}
        id="team-dashboard"
        team_id={@team_id}
      />

      <div class="flex items-center gap-1 border-b border-gray-800 pb-1">
        <button
          :for={sub <- [:activity, :cost, :graph]}
          phx-click="switch_sub_tab"
          phx-value-tab={sub}
          class={"px-3 py-1.5 text-xs font-medium rounded-lg transition-all duration-200 " <>
            if(@team_sub_tab == sub,
              do: "bg-gray-800 text-violet-400",
              else: "text-gray-500 hover:text-gray-300 hover:bg-gray-800/40")}
        >
          {team_sub_tab_label(sub)}
        </button>
      </div>

      <div class="flex-1 overflow-auto">
        {render_team_sub_tab(@team_sub_tab, assigns)}
      </div>
    </div>
    """
  end

  defp team_sub_tab_label(:activity), do: "Activity"
  defp team_sub_tab_label(:cost), do: "Cost"
  defp team_sub_tab_label(:graph), do: "Graph"

  defp render_team_sub_tab(:activity, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.TeamActivityComponent}
      id="team-activity"
      team_id={@team_id}
    />
    """
  end

  defp render_team_sub_tab(:cost, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.TeamCostComponent}
      id="team-cost"
      team_id={@team_id}
    />
    """
  end

  defp render_team_sub_tab(:graph, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.DecisionGraphComponent}
      id="team-decision-graph"
      session_id={@session_id}
    />
    """
  end

  defp ensure_index_started(project_path) do
    case GenServer.whereis(Loom.RepoIntel.Index) do
      nil ->
        Loom.RepoIntel.Index.start_link(project_path: project_path)

      _pid ->
        :ok
    end
  end

  defp short_id(id) do
    String.slice(id, 0, 8)
  end

  defp format_cost(cost) when is_number(cost) and cost > 0,
    do: :erlang.float_to_binary(cost / 1, decimals: 4)

  defp format_cost(_), do: "0.00"

  defp format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  defp format_tokens(n) when is_number(n), do: to_string(trunc(n))
  defp format_tokens(_), do: "0"

  defp parse_shell_result(result) when is_binary(result) do
    case String.split(result, "\n", parts: 2) do
      ["Exit code: " <> code_str, output] ->
        exit_code = String.to_integer(String.trim(code_str))
        %{command: "(shell)", exit_code: exit_code, output: output}

      _ ->
        %{command: "(shell)", exit_code: 0, output: result}
    end
  end

  defp parse_shell_result(_result) do
    %{command: "(shell)", exit_code: 0, output: ""}
  end
end
