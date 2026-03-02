defmodule LoomkinWeb.WorkspaceLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Session
  alias Loomkin.Session.Manager
  alias Loomkin.Teams

  require Logger

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        messages: [],
        status: :idle,
        active_tab: :files,
        model: Loomkin.Teams.ModelRouter.default_model(),
        input_text: "",
        current_tool: nil,
        current_tool_name: nil,
        file_tree_version: 0,
        selected_file: nil,
        file_content: nil,
        diffs: [],
        shell_commands: [],
        permission_request: nil,
        page_title: "Loomkin Workspace",
        team_id: params["team_id"],
        child_teams: [],
        active_team_id: params["team_id"],
        team_sub_tab: :activity,
        streaming: false,
        streaming_content: "",
        architect_phase: nil,
        plan_steps: [],
        current_step: nil
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
    tools = Loomkin.Tools.Registry.for_lead()
    project_path = File.cwd!()

    {:ok, pid} =
      Manager.start_session(
        session_id: session_id,
        model: socket.assigns.model,
        project_path: project_path,
        tools: tools,
        auto_approve: false
      )

    # Read the effective model back from the session — for resumed sessions
    # this will be the DB-persisted model, not the mount default.
    effective_model =
      try do
        GenServer.call(pid, :get_model, 5_000)
      catch
        _, _ -> socket.assigns.model
      end

    if connected?(socket) do
      Session.subscribe(session_id)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "telemetry:updates")
      ensure_index_started(project_path)

      team_id = socket.assigns[:team_id]

      if team_id do
        subscribe_to_team(team_id)

        # Recover child teams from previous pageloads
        child_ids = Teams.Manager.list_sub_teams(team_id)
        Enum.each(child_ids, &subscribe_to_team/1)
      end
    end

    # Load existing history
    messages =
      case Session.get_history(session_id) do
        {:ok, msgs} -> msgs
        _ -> []
      end

    session_metrics = Loomkin.Telemetry.Metrics.session_metrics(session_id)

    # Recover child teams if backing team exists
    team_id = socket.assigns[:team_id]
    child_teams = if team_id, do: Teams.Manager.list_sub_teams(team_id), else: []
    active_team_id = socket.assigns[:active_team_id] || team_id

    assign(socket,
      session_id: session_id,
      project_path: project_path,
      model: effective_model,
      messages: messages,
      session_cost: session_metrics.cost_usd,
      session_tokens: session_metrics.prompt_tokens + session_metrics.completion_tokens,
      page_title: "Loomkin - #{short_id(session_id)}",
      child_teams: child_teams,
      active_team_id: active_team_id
    )
  end

  # --- Events ---

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    session_id = socket.assigns.session_id
    trimmed = String.trim(text)
    # Send async to avoid blocking the LiveView process
    task = Task.async(fn -> Session.send_message(session_id, trimmed) end)

    # Optimistically show user message + thinking state immediately
    user_msg = %{role: :user, content: trimmed}

    {:noreply,
     socket
     |> assign(
       input_text: "",
       async_task: task,
       status: :thinking,
       messages: socket.assigns.messages ++ [user_msg]
     )
     |> push_event("clear-input", %{})}
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    Session.cancel(socket.assigns.session_id)
    {:noreply, assign(socket, status: :idle, streaming: false, streaming_content: "")}
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


  def handle_event("permission_response", %{"action" => action, "tool_name" => tool_name, "tool_path" => tool_path}, socket) do
    route_permission_response(socket, action, tool_name, tool_path)
    {:noreply, assign(socket, permission_request: nil)}
  end

  def handle_event("permission_response", %{"action" => action}, socket) do
    # Fallback when tool_name/tool_path come from the assign
    case socket.assigns.permission_request do
      %{tool_name: tool_name, tool_path: tool_path} ->
        route_permission_response(socket, action, tool_name, tool_path)

      _ ->
        :ok
    end

    {:noreply, assign(socket, permission_request: nil)}
  end

  def handle_event("switch_sub_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, team_sub_tab: String.to_existing_atom(tab))}
  end

  def handle_event("switch_team", %{"team-id" => team_id}, socket) do
    {:noreply, assign(socket, active_team_id: team_id)}
  end

  # --- PubSub Info ---

  def handle_info({:new_message, _session_id, %{role: :user}}, socket) do
    # User messages are added optimistically in handle_event — skip PubSub duplicate
    {:noreply, socket}
  end

  def handle_info({:new_message, _session_id, msg}, socket) do
    socket = assign(socket, messages: socket.assigns.messages ++ [msg])

    # Clear architect plan when final assistant message arrives after execution
    socket =
      if msg.role == :assistant && socket.assigns.plan_steps != [] &&
           socket.assigns.architect_phase != :executing do
        assign(socket, plan_steps: [], architect_phase: nil, current_step: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:session_status, _session_id, status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  def handle_info({:tool_executing, _source, %{tool_name: name, tool_target: target}}, socket) do
    display = if target && target != "*", do: "#{name}: #{target}", else: name
    {:noreply, assign(socket, current_tool: display, current_tool_name: name)}
  end

  def handle_info({:tool_executing, _source, %{tool_name: name}}, socket) do
    {:noreply, assign(socket, current_tool: name, current_tool_name: name)}
  end

  def handle_info({:tool_executing, _source, tool_name}, socket) when is_binary(tool_name) do
    {:noreply, assign(socket, current_tool: tool_name, current_tool_name: tool_name)}
  end

  # Team agent tool_complete (3-element tuple)
  def handle_info({:tool_complete, _agent_name, %{tool_name: _name}}, socket) do
    {:noreply, assign(socket, current_tool: nil)}
  end

  # Session tool_complete (4-element tuple with result)
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
          diff = LoomkinWeb.DiffComponent.parse_edit_result(result)
          assign(socket, diffs: socket.assigns.diffs ++ [diff])

        tool_name == "shell" ->
          cmd = parse_shell_result(result)
          assign(socket, shell_commands: socket.assigns.shell_commands ++ [cmd])

        true ->
          socket
      end

    {:noreply, socket}
  end

  # 5-tuple with source tag (from architect :session or {:agent, team_id, name})
  def handle_info({:permission_request, _id, tool_name, tool_path, source}, socket) do
    {:noreply, assign(socket, permission_request: %{tool_name: tool_name, tool_path: tool_path, source: source})}
  end

  # 4-tuple backwards compat (default to :session source)
  def handle_info({:permission_request, _session_id, tool_name, tool_path}, socket) do
    {:noreply, assign(socket, permission_request: %{tool_name: tool_name, tool_path: tool_path, source: :session})}
  end

  def handle_info({:team_available, _session_id, team_id}, socket) do
    # Auto-subscribe to backing team events when the team is created
    if connected?(socket), do: subscribe_to_team(team_id)
    {:noreply, assign(socket, team_id: team_id, active_team_id: team_id)}
  end

  def handle_info({:child_team_available, _session_id, child_team_id}, socket) do
    if connected?(socket), do: subscribe_to_team(child_team_id)

    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    {:noreply, assign(socket, :child_teams, child_teams)}
  end

  # --- Errors ---

  def handle_info({:session_cancelled, _session_id}, socket) do
    {:noreply,
     socket
     |> assign(streaming: false, streaming_content: "", status: :idle)
     |> put_flash(:info, "Request cancelled")}
  end

  def handle_info({:llm_error, _session_id, message}, socket) do
    {:noreply,
     socket
     |> assign(streaming: false, streaming_content: "", status: :idle)
     |> put_flash(:error, message)}
  end

  # --- Streaming ---

  def handle_info({:stream_start, _session_id}, socket) do
    {:noreply, assign(socket, streaming: true, streaming_content: "")}
  end

  def handle_info({:stream_delta, _session_id, %{text: chunk}}, socket) do
    {:noreply, assign(socket, streaming_content: socket.assigns.streaming_content <> chunk)}
  end

  def handle_info({:stream_end, _session_id}, socket) do
    {:noreply, assign(socket, streaming: false, streaming_content: "")}
  end

  # --- Architect Steps ---

  def handle_info({:architect_phase, phase}, socket) do
    {:noreply, assign(socket, architect_phase: phase)}
  end

  def handle_info({:architect_plan, _session_id, plan_data}, socket) do
    steps = plan_data["plan"] || []
    {:noreply, assign(socket, plan_steps: steps, current_step: nil)}
  end

  def handle_info({:architect_step, _session_id, step}, socket) do
    index =
      Enum.find_index(socket.assigns.plan_steps, fn s ->
        s["file"] == step["file"] && s["action"] == step["action"]
      end)

    {:noreply, assign(socket, current_step: index)}
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

  def handle_info({:permission_response, action, tool_name, tool_path}, socket) do
    route_permission_response(socket, action, tool_name, tool_path)
    {:noreply, assign(socket, permission_request: nil)}
  end

  # Team PubSub events -- forward to team components via send_update
  def handle_info({:agent_status, _agent_name, _status}, socket) do
    forward_to_team_components(socket)
    {:noreply, socket}
  end

  def handle_info({:task_assigned, _task_id, _agent_name}, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket}
  end

  def handle_info({:task_completed, _task_id, _agent_name, _result}, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)
    {:noreply, socket}
  end

  def handle_info({:task_started, _task_id, _owner}, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket}
  end

  def handle_info({:task_failed, _task_id, _owner, _reason}, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket}
  end

  def handle_info({:role_changed, _agent_name, _old, _new}, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket}
  end

  def handle_info({:agent_escalation, _agent_name, _old, _new}, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)
    {:noreply, socket}
  end

  def handle_info({:usage, _agent_name, _payload}, socket) do
    forward_to_cost(socket)
    {:noreply, socket}
  end

  # Agent streaming events — handled by TeamActivityComponent via its own PubSub subscription
  def handle_info({:agent_stream_start, _agent_name, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:agent_stream_delta, _agent_name, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:agent_stream_end, _agent_name, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:child_team_created, child_team_id}, socket) do
    if connected?(socket), do: subscribe_to_team(child_team_id)

    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    {:noreply, assign(socket, :child_teams, child_teams)}
  end

  def handle_info({:team_dissolved, team_id}, socket) do
    if team_id == socket.assigns.team_id do
      {:noreply, assign(socket, team_id: nil, child_teams: [], active_team_id: nil, active_tab: :files)}
    else
      child_teams = List.delete(socket.assigns.child_teams, team_id)

      active_team_id =
        if socket.assigns.active_team_id == team_id,
          do: socket.assigns.team_id,
          else: socket.assigns.active_team_id

      {:noreply, assign(socket, child_teams: child_teams, active_team_id: active_team_id)}
    end
  end

  # Telemetry metrics update
  def handle_info(:metrics_updated, socket) do
    metrics = Loomkin.Telemetry.Metrics.session_metrics(socket.assigns.session_id)

    {:noreply,
     assign(socket,
       session_cost: metrics.cost_usd,
       session_tokens: metrics.prompt_tokens + metrics.completion_tokens
     )}
  end

  # Handle async task completion
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, _response} ->
          Logger.debug("[WorkspaceLive] Async task completed successfully")
          socket

        {:error, reason} ->
          Logger.error("[WorkspaceLive] Async task returned error: #{inspect(reason)}")

          socket
          |> assign(streaming: false, streaming_content: "")
          |> put_flash(:error, format_llm_error(reason))

        other ->
          Logger.warning("[WorkspaceLive] Async task returned unexpected result: #{inspect(other)}")
          socket
      end

    {:noreply, assign(socket, async_task: nil)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if reason != :normal do
      Logger.error("[WorkspaceLive] Async task crashed: #{inspect(reason)}")
    end

    {:noreply, assign(socket, async_task: nil)}
  end

  # Catch-all for unhandled PubSub messages (team events, etc.)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-950 text-gray-100">
      <%!-- Permission modal overlay --%>
      <.live_component
        :if={@permission_request}
        module={LoomkinWeb.PermissionComponent}
        id="permission-modal"
        tool_name={@permission_request.tool_name}
        tool_path={@permission_request.tool_path}
      />

      <%!-- ── Header ── --%>
      <header class="flex items-center justify-between px-6 py-3 bg-gray-900 border-b border-gray-800 header-glow">
        <div class="flex items-center gap-4">
          <%!-- Branding --%>
          <div class="flex items-center gap-2">
            <svg class="w-7 h-7" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
              <polygon points="10,2 6,10 15,7" fill="#5B21B6"/>
              <polygon points="22,2 26,10 17,7" fill="#5B21B6"/>
              <polygon points="6,10 4,20 12,15" fill="#4B0082"/>
              <polygon points="26,10 28,20 20,15" fill="#4B0082"/>
              <polygon points="12,15 16,7 20,15" fill="#7C3AED"/>
              <polygon points="12,15 16,24 20,15" fill="#4B0082"/>
              <circle cx="12" cy="14" r="3" fill="#F59E0B"/>
              <circle cx="20" cy="14" r="3" fill="#F59E0B"/>
            </svg>
            <span class="text-xl font-bold bg-gradient-to-r from-violet-400 to-purple-400 bg-clip-text text-transparent tracking-tight">
              Loomkin
            </span>
          </div>

          <%!-- Model selector --%>
          <.live_component module={LoomkinWeb.ModelSelectorComponent} id="model-selector" model={@model} />
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
          <.live_component module={LoomkinWeb.SessionSwitcherComponent} id="session-switcher" session_id={@session_id} />

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
            module={LoomkinWeb.ChatComponent}
            id="chat"
            messages={@messages}
            status={@status}
            current_tool={@current_tool}
            streaming={@streaming}
            streaming_content={@streaming_content}
            architect_phase={@architect_phase}
            plan_steps={@plan_steps}
            current_step={@current_step}
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
                :if={@status != :thinking}
                type="submit"
                class={"flex items-center justify-center w-10 h-10 rounded-xl transition-all duration-200 " <>
                  if(@status == :idle, do: "bg-violet-600 hover:bg-violet-500 text-white send-btn-ready", else: "bg-gray-800 text-gray-600 cursor-not-allowed")}
                disabled={@status != :idle}
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5" />
                </svg>
              </button>
              <button
                :if={@status == :thinking}
                type="button"
                phx-click="cancel"
                class="flex items-center justify-center w-10 h-10 rounded-xl bg-red-600 hover:bg-red-500 text-white transition-all duration-200"
              >
                <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                  <rect x="6" y="6" width="12" height="12" rx="2" />
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
          module={LoomkinWeb.FileTreeComponent}
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
      module={LoomkinWeb.DiffComponent}
      id="diff-viewer"
      diffs={@diffs}
    />
    """
  end

  defp render_tab(:terminal, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.TerminalComponent}
      id="terminal"
      commands={@shell_commands}
    />
    """
  end

  defp render_tab(:graph, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DecisionGraphComponent}
      id="decision-graph"
      session_id={@session_id}
    />
    """
  end

  defp render_tab(:team, assigns) do
    display_team_id = assigns[:active_team_id] || assigns[:team_id]
    assigns = assign(assigns, :display_team_id, display_team_id)

    ~H"""
    <div class="flex flex-col h-full gap-3">
      <%!-- Team switcher (visible when child teams exist) --%>
      <div :if={@child_teams != []} class="flex items-center gap-1 flex-wrap border-b border-gray-800 pb-2">
        <button
          phx-click="switch_team"
          phx-value-team-id={@team_id}
          class={"text-xs px-2.5 py-1 rounded-lg font-medium transition " <>
            if(@active_team_id == @team_id,
              do: "bg-violet-600 text-white",
              else: "bg-gray-800 text-gray-400 hover:text-gray-200")}
        >
          Lead
        </button>
        <button
          :for={child_id <- @child_teams}
          phx-click="switch_team"
          phx-value-team-id={child_id}
          class={"text-xs px-2.5 py-1 rounded-lg font-medium transition " <>
            if(@active_team_id == child_id,
              do: "bg-violet-600 text-white",
              else: "bg-gray-800 text-gray-400 hover:text-gray-200")}
        >
          {short_team_id(child_id)}
        </button>
      </div>

      <.live_component
        module={LoomkinWeb.TeamDashboardComponent}
        id="team-dashboard"
        team_id={@display_team_id}
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
      module={LoomkinWeb.TeamActivityComponent}
      id="team-activity"
      team_id={@display_team_id}
    />
    """
  end

  defp render_team_sub_tab(:cost, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.TeamCostComponent}
      id="team-cost"
      team_id={@display_team_id}
    />
    """
  end

  defp render_team_sub_tab(:graph, assigns) do
    ~H"""
    <.live_component
      module={LoomkinWeb.DecisionGraphComponent}
      id="team-decision-graph"
      session_id={@session_id}
    />
    """
  end

  defp route_permission_response(socket, action, tool_name, tool_path) do
    case socket.assigns.permission_request do
      %{source: {:agent, team_id, agent_name}} ->
        case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
          {:ok, pid} -> GenServer.cast(pid, {:permission_response, action, tool_name, tool_path})
          :error -> :ok
        end

      _ ->
        Session.permission_response(socket.assigns.session_id, action, tool_name, tool_path)
    end
  end

  defp subscribe_to_team(team_id) do
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:tasks")
  end

  defp forward_to_team_components(socket) do
    forward_to_dashboard(socket)
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]
    if tid, do: send_update(LoomkinWeb.TeamActivityComponent, id: "team-activity", team_id: tid)
  end

  defp forward_to_dashboard(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]
    if tid, do: send_update(LoomkinWeb.TeamDashboardComponent, id: "team-dashboard", team_id: tid)
  end

  defp forward_to_cost(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]
    if tid, do: send_update(LoomkinWeb.TeamCostComponent, id: "team-cost", team_id: tid)
  end

  defp short_team_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_team_id(_), do: "?"

  defp ensure_index_started(project_path) do
    case GenServer.whereis(Loomkin.RepoIntel.Index) do
      nil ->
        Loomkin.RepoIntel.Index.start_link(project_path: project_path)

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

  defp format_llm_error(%{reason: reason, status: status}) when is_binary(reason) do
    if status, do: "[#{status}] #{reason}", else: reason
  end

  defp format_llm_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_llm_error(reason) when is_binary(reason), do: reason
  defp format_llm_error(reason), do: inspect(reason)

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
