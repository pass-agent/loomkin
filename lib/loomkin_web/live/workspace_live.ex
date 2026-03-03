defmodule LoomkinWeb.WorkspaceLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Session
  alias Loomkin.Session.Manager
  alias Loomkin.Teams

  require Logger
  @max_activity_events 200

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
        current_step: nil,
        activity_events: [],
        activity_known_agents: [],
        # Mission control assigns
        roster_version: 0,
        mode: :mission_control,
        focused_agent: nil,
        inspector_mode: :auto_follow,
        active_inspector_tab: :files,
        collapsed_inspector: false,
        streaming_agent: nil,
        streaming_thoughts: "",
        # Command palette
        command_palette_open: false,
        command_palette_query: "",
        command_palette_results: [],
        # Ask-user pending questions
        pending_questions: [],
        # Collaboration health score (0-100)
        collab_health: nil
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
      editing_project_path: false,
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

    # In mission control mode, also show user message in the activity feed
    socket =
      if socket.assigns.mode == :mission_control do
        user_event = %{
          id: Ecto.UUID.generate(),
          type: :message,
          agent: "You",
          content: trimmed,
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: %{from: "You", to: "Team"}
        }

        events = socket.assigns.activity_events ++ [user_event]

        events =
          if length(events) > @max_activity_events,
            do: Enum.drop(events, length(events) - @max_activity_events),
            else: events

        assign(socket, activity_events: events)
      else
        socket
      end

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

  def handle_event(
        "permission_response",
        %{"action" => action, "tool_name" => tool_name, "tool_path" => tool_path},
        socket
      ) do
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

  def handle_event("edit_project_path", _params, socket) do
    {:noreply, assign(socket, editing_project_path: true)}
  end

  def handle_event("cancel_edit_project", _params, socket) do
    {:noreply, assign(socket, editing_project_path: false)}
  end

  def handle_event("set_project_path", %{"path" => path}, socket) do
    path = String.trim(path)

    if File.dir?(path) do
      # Propagate new directory to backing team and all agents
      if team_id = socket.assigns[:team_id] do
        Teams.Manager.update_project_path(team_id, path)
      end

      {:noreply,
       socket
       |> assign(
         project_path: path,
         editing_project_path: false,
         file_tree_version: (socket.assigns[:file_tree_version] || 0) + 1
       )}
    else
      {:noreply,
       socket
       |> assign(editing_project_path: false)
       |> put_flash(:error, "Directory not found: #{path}")}
    end
  end

  def handle_event("toggle_mode", _, socket) do
    new_mode = if socket.assigns.mode == :solo, do: :mission_control, else: :solo
    {:noreply, assign(socket, mode: new_mode)}
  end

  def handle_event("keyboard_shortcut", %{"key" => "toggle_mode"}, socket) do
    handle_event("toggle_mode", %{}, socket)
  end

  def handle_event("keyboard_shortcut", %{"key" => "cancel"}, socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("keyboard_shortcut", %{"key" => "escape"}, socket) do
    if socket.assigns.command_palette_open do
      {:noreply,
       assign(socket,
         command_palette_open: false,
         command_palette_query: "",
         command_palette_results: []
       )}
    else
      {:noreply,
       assign(socket, focused_agent: nil, inspector_mode: :auto_follow, permission_request: nil)}
    end
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_input"}, socket) do
    {:noreply, push_event(socket, "focus-input", %{})}
  end


  def handle_event("keyboard_shortcut", %{"key" => "command_palette"}, socket) do
    if socket.assigns.command_palette_open do
      {:noreply,
       assign(socket,
         command_palette_open: false,
         command_palette_query: "",
         command_palette_results: []
       )}
    else
      results = build_palette_results(socket, "")
      {:noreply, assign(socket, command_palette_open: true, command_palette_results: results)}
    end
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_panel_4"}, socket) do
    {:noreply, assign(socket, active_inspector_tab: :graph, inspector_mode: :pinned)}
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_panel_5"}, socket) do
    {:noreply, assign(socket, active_inspector_tab: :chat, inspector_mode: :pinned)}
  end

  def handle_event("keyboard_shortcut", %{"key" => "jump_active_agent"}, socket) do
    agents = roster_agents(socket.assigns[:active_team_id])

    active =
      Enum.find(agents, fn a -> a[:status] in [:thinking, :executing_tool] end) ||
        List.first(agents)

    if active do
      {:noreply, assign(socket, focused_agent: active[:name], inspector_mode: :pinned)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("keyboard_shortcut", %{"key" => "toggle_activity"}, socket) do
    new_tab = if socket.assigns.team_sub_tab == :activity, do: :graph, else: :activity
    {:noreply, assign(socket, team_sub_tab: new_tab)}
  end

  def handle_event("palette_search", %{"value" => query}, socket) do
    results = build_palette_results(socket, query)

    {:noreply,
     assign(socket, command_palette_query: query, command_palette_results: results)}
  end

  def handle_event("palette_select", %{"type" => "agent", "value" => agent_name}, socket) do
    {:noreply,
     assign(socket,
       focused_agent: agent_name,
       inspector_mode: :pinned,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  @palette_valid_tabs ~w(files diff terminal graph chat)
  def handle_event("palette_select", %{"type" => "tab", "value" => tab}, socket)
      when tab in @palette_valid_tabs do
    {:noreply,
     assign(socket,
       active_inspector_tab: String.to_existing_atom(tab),
       inspector_mode: :pinned,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  def handle_event("palette_select", %{"type" => "action", "value" => "toggle_mode"}, socket) do
    new_mode = if socket.assigns.mode == :solo, do: :mission_control, else: :solo

    {:noreply,
     assign(socket,
       mode: new_mode,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  def handle_event("palette_select", %{"type" => "action", "value" => "focus_input"}, socket) do
    {:noreply,
     socket
     |> assign(
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )
     |> push_event("focus-input", %{})}
  end

  @palette_valid_sub_tabs ~w(activity graph)
  def handle_event("palette_select", %{"type" => "sub_tab", "value" => tab}, socket)
      when tab in @palette_valid_sub_tabs do
    {:noreply,
     assign(socket,
       team_sub_tab: String.to_existing_atom(tab),
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  def handle_event("close_command_palette", _params, socket) do
    {:noreply,
     assign(socket,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  # --- Ask User ---

  def handle_event("ask_user_answer", %{"question-id" => question_id, "answer" => answer}, socket) do
    {question, remaining} =
      case Enum.split_with(socket.assigns.pending_questions, &(&1.question_id == question_id)) do
        {[q], rest} -> {q, rest}
        _ -> {nil, socket.assigns.pending_questions}
      end

    if question do
      if answer == "__collective__" do
        # Forward question to peer agents for collective decision
        handle_collective_decision(question, socket.assigns.pending_questions)
        {:noreply, assign(socket, pending_questions: remaining)}
      else
        # Send answer directly back to the waiting agent
        send_ask_user_answer(question_id, answer)
        {:noreply, assign(socket, pending_questions: remaining)}
      end
    else
      {:noreply, socket}
    end
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

  def handle_info(
        {:tool_executing, source, %{tool_name: name, tool_target: target}} = event,
        socket
      ) do
    display = if target && target != "*", do: "#{name}: #{target}", else: name

    socket =
      socket
      |> forward_to_activity(event)
      |> maybe_auto_follow(source, %{tool_name: name, path: target})
      |> assign(current_tool: display, current_tool_name: name)

    {:noreply, socket}
  end

  def handle_info({:tool_executing, source, %{tool_name: name}} = event, socket) do
    socket =
      socket
      |> forward_to_activity(event)
      |> maybe_auto_follow(source, %{tool_name: name})
      |> assign(current_tool: name, current_tool_name: name)

    {:noreply, socket}
  end

  def handle_info({:tool_executing, _source, tool_name}, socket) when is_binary(tool_name) do
    {:noreply, assign(socket, current_tool: tool_name, current_tool_name: tool_name)}
  end

  # Team agent tool_complete (3-element tuple)
  def handle_info({:tool_complete, _agent_name, %{tool_name: _name}} = event, socket) do
    socket =
      socket
      |> forward_to_activity(event)
      |> assign(current_tool: nil)

    {:noreply, socket}
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
    {:noreply,
     assign(socket,
       permission_request: %{tool_name: tool_name, tool_path: tool_path, source: source}
     )}
  end

  # 4-tuple backwards compat (default to :session source)
  def handle_info({:permission_request, _session_id, tool_name, tool_path}, socket) do
    {:noreply,
     assign(socket,
       permission_request: %{tool_name: tool_name, tool_path: tool_path, source: :session}
     )}
  end

  def handle_info({:team_available, _session_id, team_id}, socket) do
    # Auto-subscribe to backing team events when the team is created
    if connected?(socket), do: subscribe_to_team(team_id)
    {:noreply, assign(socket, team_id: team_id, active_team_id: team_id, mode: :mission_control)}
  end

  def handle_info({:child_team_available, _session_id, child_team_id}, socket) do
    if connected?(socket), do: subscribe_to_team(child_team_id)

    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    socket = update(socket, :roster_version, &((&1 || 0) + 1))
    {:noreply, assign(socket, child_teams: child_teams, mode: :mission_control)}
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

  def handle_info({:select_prompt, prompt}, socket) do
    session_id = socket.assigns.session_id
    task = Task.async(fn -> Session.send_message(session_id, prompt) end)
    user_msg = %{role: :user, content: prompt}

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
  def handle_info({:agent_status, _agent_name, _status} = event, socket) do
    forward_to_team_components(socket)
    socket = update(socket, :roster_version, &((&1 || 0) + 1))
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_assigned, _task_id, _agent_name} = event, socket) do
    forward_to_dashboard(socket)
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_completed, _task_id, _agent_name, _result} = event, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_started, _task_id, _owner} = event, socket) do
    forward_to_dashboard(socket)
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_failed, _task_id, _owner, _reason} = event, socket) do
    forward_to_dashboard(socket)
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:role_changed, _agent_name, _old, _new} = event, socket) do
    forward_to_dashboard(socket)
    socket = update(socket, :roster_version, &((&1 || 0) + 1))
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:agent_escalation, _agent_name, _old, _new} = event, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:usage, _agent_name, _payload}, socket) do
    forward_to_cost(socket)
    {:noreply, socket}
  end

  # Agent error events (max iterations exceeded, tool failures, etc.)
  def handle_info({:agent_error, _agent_name, _payload} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  # Agent streaming events — show thoughts live in activity feed
  def handle_info({:agent_stream_start, agent_name, _payload}, socket) do
    # Start accumulating this agent's thoughts
    {:noreply, assign(socket, streaming_agent: agent_name, streaming_thoughts: "")}
  end

  def handle_info({:agent_stream_delta, agent_name, payload}, socket) do
    chunk =
      case payload do
        %{text: t} when is_binary(t) -> t
        %{content: c} when is_binary(c) -> c
        %{delta: d} when is_binary(d) -> d
        c when is_binary(c) -> c
        _ -> ""
      end

    current = socket.assigns[:streaming_thoughts] || ""
    updated = current <> chunk

    # Update or insert a live "thinking" event in the activity feed
    thinking_id = "thinking-#{agent_name}"
    events = socket.assigns.activity_events

    existing_idx = Enum.find_index(events, &(&1.id == thinking_id))

    events =
      if existing_idx do
        List.update_at(events, existing_idx, fn ev ->
          %{ev | content: updated, timestamp: DateTime.utc_now()}
        end)
      else
        events ++
          [
            %{
              id: thinking_id,
              type: :thinking,
              agent: agent_name,
              content: updated,
              timestamp: DateTime.utc_now(),
              expanded: true,
              metadata: %{live: true}
            }
          ]
      end

    {:noreply, assign(socket, activity_events: events, streaming_thoughts: updated)}
  end

  def handle_info({:agent_stream_end, agent_name, _payload}, socket) do
    # Finalize the thinking event — mark it as no longer live
    thinking_id = "thinking-#{agent_name}"
    events = socket.assigns.activity_events

    events =
      Enum.map(events, fn ev ->
        if ev.id == thinking_id do
          %{ev | metadata: Map.delete(ev.metadata || %{}, :live)}
        else
          ev
        end
      end)

    {:noreply,
     assign(socket, activity_events: events, streaming_agent: nil, streaming_thoughts: "")}
  end

  def handle_info({:child_team_created, child_team_id}, socket) do
    if connected?(socket), do: subscribe_to_team(child_team_id)

    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    socket = update(socket, :roster_version, &((&1 || 0) + 1))
    {:noreply, assign(socket, :child_teams, child_teams)}
  end

  def handle_info({:team_dissolved, team_id}, socket) do
    if team_id == socket.assigns.team_id do
      {:noreply,
       assign(socket,
         team_id: nil,
         child_teams: [],
         active_team_id: nil,
         active_tab: :files,
         mode: :solo,
         focused_agent: nil,
         inspector_mode: :auto_follow
       )}
    else
      child_teams = List.delete(socket.assigns.child_teams, team_id)

      active_team_id =
        if socket.assigns.active_team_id == team_id,
          do: socket.assigns.team_id,
          else: socket.assigns.active_team_id

      # Switch back to solo if no teams remain
      mode =
        if child_teams == [] && socket.assigns.team_id == nil,
          do: :solo,
          else: socket.assigns.mode

      socket = update(socket, :roster_version, &((&1 || 0) + 1))

      {:noreply,
       assign(socket, child_teams: child_teams, active_team_id: active_team_id, mode: mode)}
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
          Logger.warning(
            "[WorkspaceLive] Async task returned unexpected result: #{inspect(other)}"
          )

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

  # Team decision and context events — buffer for activity feed
  def handle_info({:decision_logged, _node_id, _agent_name} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:context_update, _from_agent, _payload} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:context_offloaded, _agent_name, _payload} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  # Messages from AgentRosterComponent
  def handle_info({:focus_agent, agent_name}, socket) do
    {:noreply, assign(socket, focused_agent: agent_name, inspector_mode: :pinned)}
  end

  def handle_info({:unpin_agent}, socket) do
    {:noreply, assign(socket, focused_agent: nil, inspector_mode: :auto_follow)}
  end

  # Messages from ContextInspectorComponent
  def handle_info({:inspector_tab, tab}, socket) do
    {:noreply, assign(socket, active_inspector_tab: tab, inspector_mode: :pinned)}
  end

  def handle_info({:resume_follow}, socket) do
    {:noreply, assign(socket, inspector_mode: :auto_follow)}
  end

  # From activity feed file clicks
  def handle_info({:inspector_file, path}, socket) do
    {:noreply, assign(socket, active_inspector_tab: :files, selected_file: path)}
  end

  # New event types for activity feed
  def handle_info({:keeper_created, _payload} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:tasks_unblocked, _task_ids} = event, socket) do
    {:noreply, forward_to_activity(socket, event)}
  end

  # --- Ask User questions from agents ---

  def handle_info({:ask_user_question, question}, socket) do
    questions = socket.assigns.pending_questions ++ [question]

    event = %{
      id: Ecto.UUID.generate(),
      type: :ask_user,
      agent: question.agent_name,
      content: question.question,
      timestamp: DateTime.utc_now(),
      expanded: true,
      metadata: %{question_id: question.question_id, options: question.options}
    }

    socket =
      socket
      |> assign(pending_questions: questions)
      |> append_activity_event(event)

    {:noreply, socket}
  end

  def handle_info({:ask_user_answered, question_id, answer}, socket) do
    remaining = Enum.reject(socket.assigns.pending_questions, &(&1.question_id == question_id))

    event = %{
      id: Ecto.UUID.generate(),
      type: :message,
      agent: "system",
      content: "Question answered: #{answer}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }

    socket =
      socket
      |> assign(pending_questions: remaining)
      |> append_activity_event(event)

    {:noreply, socket}
  end

  # Collaboration events — render in activity feed (metrics recorded backend-side)
  def handle_info({:collab_event, payload}, socket) do
    socket =
      if team_id = socket.assigns[:team_id] do
        score = Loomkin.Teams.CollaborationMetrics.collaboration_score(team_id)
        assign(socket, collab_health: score)
      else
        socket
      end

    {:noreply, forward_to_activity(socket, {:collab_event, payload})}
  end

  # Catch-all for unhandled PubSub messages (team events, etc.)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div
      class="flex flex-col h-screen overflow-hidden bg-gray-950 text-gray-100"
      phx-hook="KeyboardShortcuts"
      id="workspace-shortcuts"
    >
      <%!-- Permission modal overlay --%>
      <.live_component
        :if={@permission_request}
        module={LoomkinWeb.PermissionComponent}
        id="permission-modal"
        tool_name={@permission_request.tool_name}
        tool_path={@permission_request.tool_path}
      />

      <%!-- Command palette overlay --%>
      {render_command_palette(assigns)}

      <%!-- ── Header ── --%>
      <header class="flex flex-col gap-3 bg-gray-900 border-b border-gray-800 header-glow px-3 py-3 sm:px-4 lg:flex-row lg:items-center lg:justify-between lg:px-6">
        <div class="flex min-w-0 flex-wrap items-center gap-3 lg:gap-4">
          <%!-- Branding --%>
          <div class="flex items-center gap-2">
            <svg class="w-7 h-7" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
              <polygon points="10,2 6,10 15,7" fill="#5B21B6" />
              <polygon points="22,2 26,10 17,7" fill="#5B21B6" />
              <polygon points="6,10 4,20 12,15" fill="#4B0082" />
              <polygon points="26,10 28,20 20,15" fill="#4B0082" />
              <polygon points="12,15 16,7 20,15" fill="#7C3AED" />
              <polygon points="12,15 16,24 20,15" fill="#4B0082" />
              <circle cx="12" cy="14" r="3" fill="#F59E0B" />
              <circle cx="20" cy="14" r="3" fill="#F59E0B" />
            </svg>
            <span class="text-xl font-bold bg-gradient-to-r from-violet-400 to-purple-400 bg-clip-text text-transparent tracking-tight">
              Loomkin
            </span>
          </div>

          <%!-- Model selector --%>
          <.live_component
            module={LoomkinWeb.ModelSelectorComponent}
            id="model-selector"
            model={@model}
          />

          <%!-- Project path switcher --%>
          <div class="hidden items-center gap-2 text-sm text-gray-400 md:flex">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-4 h-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
            <%= if @editing_project_path do %>
              <form phx-submit="set_project_path" class="flex items-center gap-1">
                <input
                  type="text"
                  name="path"
                  value={@project_path}
                  class="bg-gray-800 border border-gray-700 rounded px-2 py-0.5 text-sm text-gray-200 w-64"
                  autofocus
                />
                <button type="submit" class="text-xs text-violet-400 hover:text-violet-300">
                  Go
                </button>
                <button
                  type="button"
                  phx-click="cancel_edit_project"
                  class="text-xs text-gray-500 hover:text-gray-400"
                >
                  Cancel
                </button>
              </form>
            <% else %>
              <button
                phx-click="edit_project_path"
                class="hover:text-gray-200 transition truncate max-w-xs"
                title={@project_path}
              >
                {@project_path}
              </button>
            <% end %>
          </div>

          <%!-- Team indicator (mission control mode) --%>
          <div
            :if={@mode == :mission_control && @active_team_id}
            class="flex items-center gap-2 min-w-0"
          >
            <span class="text-xs text-violet-400 font-medium">
              Team: {short_team_id(@active_team_id)}
            </span>
            <span class="hidden text-xs text-gray-500 sm:inline">
              {roster_agent_count(@active_team_id)} agents
            </span>
            <select
              :if={@child_teams != []}
              phx-change="switch_team"
              name="team-id"
              class="max-w-[11rem] truncate text-xs bg-gray-800 border border-gray-700 rounded px-1.5 py-0.5 text-gray-300 focus:outline-none focus:ring-1 focus:ring-violet-500/50"
            >
              <option
                :for={tid <- [@team_id | @child_teams]}
                value={tid}
                selected={tid == @active_team_id}
              >
                {short_team_id(tid)}
              </option>
            </select>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2 sm:gap-3 lg:justify-end">
          <%!-- Mode toggle (visible when team exists) --%>
          <button
            :if={@team_id}
            phx-click="toggle_mode"
            class="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all duration-200 bg-gray-800/60 hover:bg-gray-800 text-gray-300 hover:text-violet-400"
          >
            <span :if={@mode == :solo} class="hero-user-group-mini inline-block w-3.5 h-3.5" />
            <span
              :if={@mode == :mission_control}
              class="hero-chat-bubble-left-right-mini inline-block w-3.5 h-3.5"
            />
            {if @mode == :mission_control, do: "Solo", else: "Mission Control"}
          </button>

          <%!-- Cost pill --%>
          <a
            href="/dashboard"
            class="flex items-center gap-1.5 bg-gray-800/60 hover:bg-gray-800 rounded-full px-3 py-1.5 transition-colors group"
          >
            <.icon
              name="hero-sparkles-mini"
              class="w-3.5 h-3.5 text-violet-400 group-hover:text-violet-300"
            />
            <span class="text-xs font-mono text-gray-300">${format_cost(@session_cost)}</span>
            <span class="text-[10px] text-gray-500 font-mono">
              {format_tokens(@session_tokens)} tok
            </span>
          </a>

          <%!-- Session switcher --%>
          <.live_component
            module={LoomkinWeb.SessionSwitcherComponent}
            id="session-switcher"
            session_id={@session_id}
          />

          <%!-- Status indicator --%>
          <div class={"flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-medium transition-all duration-300 " <> status_pill_class(@status)}>
            <span class={status_dot_class(@status)} />
            {status_label(@status, @current_tool_name)}
          </div>
        </div>
      </header>

      <%!-- ── Main Content — branches on mode ── --%>
      <div class="flex flex-1 min-h-0 flex-col xl:flex-row">
        {render_mode(@mode, assigns)}
      </div>
    </div>
    """
  end

  # --- Solo Mode (current layout, minus :team tab) ---

  defp render_mode(:solo, assigns) do
    ~H"""
    <%!-- Left: Chat + Input --%>
    <div class="flex-1 flex flex-col min-w-0 min-h-0">
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

      {render_input_bar(assigns)}
    </div>

    <%!-- Right: Sidebar --%>
    <div class="h-[18rem] w-full border-t border-gray-800 bg-gray-900/50 flex flex-col xl:h-auto xl:w-96 xl:border-l xl:border-t-0">
      <%!-- Sidebar tab bar (no :team tab — that's in mission control) --%>
      <div class="flex items-center gap-1 px-3 py-2 border-b border-gray-800 bg-gray-900/80 overflow-x-auto flex-shrink-0">
        <button
          :for={tab <- [:files, :diff, :terminal, :graph]}
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
      <div
        class="flex-1 overflow-auto p-4 tab-content-enter"
        phx-hook="TabTransition"
        id={"tab-content-#{@active_tab}"}
      >
        {render_tab(@active_tab, assigns)}
      </div>
    </div>
    """
  end

  # --- Mission Control Mode (three-panel layout) ---

  defp render_mode(:mission_control, assigns) do
    ~H"""
    <%!-- Left: Agent Roster (w-56) --%>
    <.live_component
      module={LoomkinWeb.AgentRosterComponent}
      id="agent-roster"
      team_id={@active_team_id}
      agents={roster_agents(@active_team_id)}
      tasks={roster_tasks(@active_team_id)}
      budget={roster_budget(@active_team_id)}
      focused_agent={@focused_agent}
      roster_version={@roster_version}
    />

    <%!-- Center: Activity Feed (flex-1) + Input Bar --%>
    <div class="flex-1 flex flex-col min-w-0 min-h-0">
      <.live_component
        module={LoomkinWeb.TeamActivityComponent}
        id="activity-feed"
        team_id={@active_team_id}
        events={@activity_events}
        known_agents={@activity_known_agents}
        focused_agent={@focused_agent}
      />

      <%!-- Pending ask_user questions --%>
      <div :if={@pending_questions != []} class="border-t border-violet-500/20 bg-gray-900/90 px-3 py-2">
        <.live_component
          module={LoomkinWeb.AskUserComponent}
          id="ask-user-questions"
          questions={@pending_questions}
        />
      </div>

      {render_input_bar(assigns)}
    </div>

    <%!-- Right: Context Inspector (w-80, collapsible) --%>
    <.live_component
      module={LoomkinWeb.ContextInspectorComponent}
      id="context-inspector"
      active_inspector_tab={@active_inspector_tab}
      focused_agent={@focused_agent}
      inspector_mode={@inspector_mode}
      file_tree_version={@file_tree_version}
      selected_file={@selected_file}
      file_content={@file_content}
      diffs={@diffs}
      shell_commands={@shell_commands}
      messages={@messages}
      status={@status}
      current_tool={@current_tool}
      streaming={@streaming}
      streaming_content={@streaming_content}
      architect_phase={@architect_phase}
      plan_steps={@plan_steps}
      current_step={@current_step}
      session_id={@session_id}
      team_id={@active_team_id}
      project_path={@project_path}
    />
    """
  end

  # --- Shared input bar (used by both modes) ---

  defp render_input_bar(assigns) do
    ~H"""
    <form phx-submit="send_message" class="border-t border-gray-800 bg-gray-900/80 p-3 sm:p-4">
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
          class="flex items-center justify-center w-10 h-10 rounded-xl bg-red-600 hover:bg-red-500 text-white transition-all duration-200"
        >
          <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
            <rect x="6" y="6" width="12" height="12" rx="2" />
          </svg>
        </button>
      </div>
      <p class="text-[10px] text-gray-600 mt-1.5 pl-1">
        <kbd class="px-1 py-0.5 bg-gray-800/60 rounded text-gray-500 font-mono text-[9px]">
          Shift+Enter
        </kbd>
        for new line
      </p>
    </form>
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

  defp tab_icon(:files),
    do: raw("<span class=\"hero-folder-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:diff),
    do: raw("<span class=\"hero-code-bracket-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:terminal),
    do: raw("<span class=\"hero-command-line-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:graph),
    do: raw("<span class=\"hero-share-mini inline-block w-3.5 h-3.5\"></span>")

  defp tab_icon(:team),
    do: raw("<span class=\"hero-user-group-mini inline-block w-3.5 h-3.5\"></span>")

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
        <div
          id={"file-preview-#{@selected_file}"}
          phx-hook="SyntaxHighlight"
          class="flex-1 overflow-auto file-preview-container"
        >
          <pre class="file-preview-pre"><code class={"language-#{language_from_path(@selected_file)}"}>{@file_content}</code></pre>
        </div>
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
      team_id={@active_team_id}
    />
    """
  end

  defp render_tab(:team, assigns) do
    display_team_id = assigns[:active_team_id] || assigns[:team_id]
    assigns = assign(assigns, :display_team_id, display_team_id)

    ~H"""
    <div class="flex flex-col h-full gap-3">
      <%!-- Team switcher (visible when child teams exist) --%>
      <div
        :if={@child_teams != []}
        class="flex items-center gap-1 flex-wrap border-b border-gray-800 pb-2"
      >
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
        <span :if={@collab_health} class="ml-auto flex items-center gap-1 text-xs" title={"Collaboration health: #{@collab_health}/100"}>
          <span class={"inline-block w-2 h-2 rounded-full " <> collab_health_color(@collab_health)} />
          <span class="text-gray-500">{@collab_health}</span>
        </span>
      </div>

      <%!-- Activity feed: always mounted, hidden when not selected --%>
      <div class={if @team_sub_tab == :activity, do: "flex-1 overflow-auto", else: "hidden"}>
        <.live_component
          module={LoomkinWeb.TeamActivityComponent}
          id="team-activity"
          team_id={@display_team_id}
          events={@activity_events}
          known_agents={@activity_known_agents}
        />
      </div>

      <%!-- Other sub-tab content --%>
      <div :if={@team_sub_tab != :activity} class="flex-1 overflow-auto">
        {render_team_sub_tab(@team_sub_tab, assigns)}
      </div>
    </div>
    """
  end

  defp team_sub_tab_label(:activity), do: "Activity"
  defp team_sub_tab_label(:cost), do: "Cost"
  defp team_sub_tab_label(:graph), do: "Graph"

  defp collab_health_color(score) when score >= 70, do: "bg-green-400"
  defp collab_health_color(score) when score >= 40, do: "bg-yellow-400"
  defp collab_health_color(_score), do: "bg-red-400"

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
      team_id={@display_team_id}
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
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:context")
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:decisions")
  end

  defp forward_to_activity(socket, pubsub_event) do
    case activity_event_from(pubsub_event) do
      nil ->
        socket

      :merge_tool_result ->
        merge_tool_result(socket, pubsub_event)

      event ->
        events = socket.assigns.activity_events ++ [event]

        events =
          if length(events) > @max_activity_events,
            do: Enum.drop(events, length(events) - @max_activity_events),
            else: events

        agents = socket.assigns.activity_known_agents

        agents =
          case trackable_agent_name(event.agent) do
            nil -> agents
            name -> if name in agents, do: agents, else: agents ++ [name]
          end

        assign(socket, activity_events: events, activity_known_agents: agents)
    end
  end

  # Append a pre-formed activity event (bypasses activity_event_from pattern matching)
  defp append_activity_event(socket, event) do
    events = socket.assigns.activity_events ++ [event]

    events =
      if length(events) > @max_activity_events,
        do: Enum.drop(events, length(events) - @max_activity_events),
        else: events

    agents = socket.assigns.activity_known_agents

    agents =
      case trackable_agent_name(event.agent) do
        nil -> agents
        name -> if name in agents, do: agents, else: agents ++ [name]
      end

    assign(socket, activity_events: events, activity_known_agents: agents)
  end

  # Merge tool_complete result into the most recent tool_executing event for that agent
  defp merge_tool_result(socket, {:tool_complete, agent, %{result: result} = payload}) do
    tool_name = payload[:tool_name]
    result_str = to_string(result)

    # Truncate very long results but keep enough to be useful
    truncated =
      if String.length(result_str) > 2000 do
        String.slice(result_str, 0, 2000) <> "\n... (truncated)"
      else
        result_str
      end

    events = socket.assigns.activity_events

    # Find the last tool_call event from this agent (most recent match)
    match_idx =
      events
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {ev, idx} ->
        if ev.type == :tool_call && ev.agent == agent &&
             (is_nil(tool_name) || (ev.metadata || %{})[:tool_name] == tool_name) &&
             is_nil((ev.metadata || %{})[:result]) do
          idx
        end
      end)

    events =
      if match_idx do
        List.update_at(events, match_idx, fn ev ->
          metadata = Map.put(ev.metadata || %{}, :result, truncated)
          %{ev | metadata: metadata, expanded: false}
        end)
      else
        # No matching executing event — create standalone result event
        events ++
          [
            %{
              id: Ecto.UUID.generate(),
              type: :tool_call,
              agent: agent,
              content: tool_name || "tool result",
              timestamp: DateTime.utc_now(),
              expanded: false,
              metadata: %{tool_name: tool_name, result: truncated}
            }
          ]
      end

    assign(socket, activity_events: events)
  end

  defp merge_tool_result(socket, _), do: socket

  # --- Tool events: executing creates the card, complete merges result into it ---

  defp activity_event_from({:tool_executing, agent, %{tool_name: name} = payload}) do
    target = payload[:tool_target]
    content = tool_display_content(name, target, payload)

    %{
      id: "tool-#{agent}-#{System.unique_integer([:positive])}",
      type: :tool_call,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{
        tool_name: name,
        file_path: target,
        result: nil
      }
    }
  end

  # tool_complete is handled specially — not via activity_event_from, see forward_to_activity
  defp activity_event_from({:tool_complete, _agent, _payload}), do: :merge_tool_result

  # --- Agent status: only surface meaningful transitions, skip noisy ones ---

  defp activity_event_from({:agent_status, _agent, status}) when status in [:idle, :working],
    do: nil

  defp activity_event_from({:agent_status, agent, :blocked}) do
    %{
      id: Ecto.UUID.generate(),
      type: :error,
      agent: agent,
      content: "Blocked — waiting for input",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:agent_status, agent, :error}) do
    %{
      id: Ecto.UUID.generate(),
      type: :error,
      agent: agent,
      content: "Encountered an error",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:agent_status, _agent, _}), do: nil

  defp activity_event_from({:agent_error, agent, payload}) do
    content =
      cond do
        is_map(payload) && payload[:max] ->
          "Exceeded max iterations (#{payload[:max]})"

        is_map(payload) && payload[:error] ->
          "#{payload[:tool_name] || "Tool"}: #{String.slice(to_string(payload[:error]), 0, 300)}"

        is_map(payload) && payload[:reason] ->
          "Error: #{String.slice(to_string(payload[:reason]), 0, 300)}"

        true ->
          "Encountered an error"
      end

    %{
      id: Ecto.UUID.generate(),
      type: :error,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  # --- Streaming: skip start/end noise ---

  defp activity_event_from({:agent_stream_start, _agent, _payload}), do: nil
  defp activity_event_from({:agent_stream_delta, _agent, _payload}), do: nil
  defp activity_event_from({:agent_stream_end, _agent, _payload}), do: nil

  # --- Task lifecycle: human-readable content ---

  defp activity_event_from({:task_assigned, _task_id, agent}) do
    %{
      id: Ecto.UUID.generate(),
      type: :task_assigned,
      agent: agent,
      content: "Picked up a task",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:task_started, _task_id, _agent}) do
    nil
    # Task start is redundant with task_assigned — skip to reduce noise
    |> then(fn _ -> nil end)
  end

  defp activity_event_from({:task_completed, _task_id, agent, result}) do
    content =
      case result do
        r when is_binary(r) and byte_size(r) > 0 -> "Completed: #{String.slice(r, 0, 300)}"
        _ -> "Task completed"
      end

    %{
      id: Ecto.UUID.generate(),
      type: :task_complete,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:task_failed, _task_id, agent, reason}) do
    content = "Task failed: #{String.slice(to_string(reason), 0, 300)}"

    %{
      id: Ecto.UUID.generate(),
      type: :error,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  # --- Inter-agent communication ---

  defp activity_event_from({:decision_logged, _node_id, agent}) do
    %{
      id: Ecto.UUID.generate(),
      type: :decision,
      agent: agent,
      content: "Logged a decision",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:context_update, agent, payload}) do
    content =
      case payload do
        %{type: :discovery, content: c} when is_binary(c) -> c
        %{content: c} when is_binary(c) -> c
        _ -> "Shared a discovery"
      end

    %{
      id: Ecto.UUID.generate(),
      type: :discovery,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:context_offloaded, agent, payload}) do
    topic = if is_map(payload), do: payload[:topic] || "context", else: "context"

    %{
      id: Ecto.UUID.generate(),
      type: :context_offload,
      agent: agent,
      content: "Stored context: #{topic}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:role_changed, agent, old_role, new_role}) do
    %{
      id: Ecto.UUID.generate(),
      type: :message,
      agent: agent,
      content: "Changed role: #{old_role} → #{new_role}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:agent_escalation, agent, from, to}) do
    %{
      id: Ecto.UUID.generate(),
      type: :message,
      agent: agent,
      content: "Escalated model: #{from} → #{to}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:keeper_created, payload}) do
    agent =
      if is_map(payload), do: payload[:agent] || payload[:source] || "system", else: "system"

    topic = if is_map(payload), do: payload[:topic] || "context", else: "context"
    tokens = if is_map(payload), do: payload[:tokens], else: nil
    suffix = if tokens, do: " (#{format_token_count(tokens)} tokens)", else: ""

    %{
      id: Ecto.UUID.generate(),
      type: :context_offload,
      agent: agent,
      content: "Created keeper: #{topic}#{suffix}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:tasks_unblocked, task_ids}) do
    count = length(task_ids)

    %{
      id: Ecto.UUID.generate(),
      type: :message,
      agent: "system",
      content: "#{count} task#{if count == 1, do: "", else: "s"} unblocked",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:collab_event, payload}) do
    # Map collab event type to an activity event type for styling
    event_type =
      case payload.type do
        :conflict_detected -> :error
        :consensus_reached -> :decision
        :task_rebalanced -> :task_assigned
        _ -> :message
      end

    agent =
      case payload.agents do
        [first | _] -> first
        _ -> "system"
      end

    %{
      id: Ecto.UUID.generate(),
      type: event_type,
      agent: agent,
      content: payload.description,
      timestamp: payload.timestamp,
      expanded: false,
      metadata: Map.put(payload.metadata || %{}, :collab_type, payload.type)
    }
  end

  defp activity_event_from(_), do: nil

  # --- Human-readable tool descriptions ---

  defp tool_display_content("file_read", target, _payload) when is_binary(target),
    do: "Reading #{target}"

  defp tool_display_content("file_read", _, _), do: "Reading a file"

  defp tool_display_content("file_write", target, _payload) when is_binary(target),
    do: "Writing #{target}"

  defp tool_display_content("file_edit", target, _payload) when is_binary(target),
    do: "Editing #{target}"

  defp tool_display_content("file_search", _, payload) do
    pattern = payload[:pattern] || payload[:args] || ""
    "Searching files: #{pattern}"
  end

  defp tool_display_content("content_search", _, payload) do
    pattern = payload[:pattern] || payload[:query] || ""
    "Searching content: #{pattern}"
  end

  defp tool_display_content("directory_list", target, _payload) when is_binary(target),
    do: "Listing #{target}/"

  defp tool_display_content("directory_list", _, _), do: "Listing directory"

  defp tool_display_content("shell", _, payload) do
    cmd = payload[:command] || ""
    "Running: #{String.slice(to_string(cmd), 0, 80)}"
  end

  defp tool_display_content("git", _, payload) do
    op = payload[:operation] || ""
    "Git #{op}"
  end

  defp tool_display_content("decision_log", _, _), do: "Logging decision"
  defp tool_display_content("decision_query", _, _), do: "Querying decisions"
  defp tool_display_content("peer_message", _, _), do: "Sending message"
  defp tool_display_content("peer_discovery", _, _), do: "Broadcasting discovery"
  defp tool_display_content("peer_create_task", _, _), do: "Creating task"
  defp tool_display_content("peer_complete_task", _, _), do: "Completing task"
  defp tool_display_content("peer_ask_question", _, _), do: "Asking the team"
  defp tool_display_content("context_offload", _, _), do: "Offloading context"
  defp tool_display_content("context_retrieve", _, _), do: "Retrieving context"
  defp tool_display_content("ask_user", _, _), do: "Asking the user"

  defp tool_display_content(name, target, _payload) when is_binary(target),
    do: "#{name} on #{target}"

  defp tool_display_content(name, _, _), do: name

  defp format_token_count(n) when is_integer(n) and n >= 1000,
    do: "#{Float.round(n / 1000, 1)}k"

  defp format_token_count(n) when is_integer(n), do: "#{n}"
  defp format_token_count(_), do: "?"

  # --- Auto-follow logic for mission control ---

  defp maybe_auto_follow(socket, agent_name, payload) do
    agent = if is_binary(agent_name), do: agent_name, else: nil

    if socket.assigns.mode == :mission_control && socket.assigns.inspector_mode == :auto_follow do
      case payload[:tool_name] do
        name when name in ["file_read", "content_search", "file_search"] ->
          assign(socket,
            active_inspector_tab: :files,
            focused_agent: agent,
            selected_file: payload[:path]
          )

        name when name in ["file_write", "file_edit"] ->
          assign(socket, active_inspector_tab: :diff, focused_agent: agent)

        "shell" ->
          assign(socket, active_inspector_tab: :terminal, focused_agent: agent)

        "decision_log" ->
          assign(socket, active_inspector_tab: :graph, focused_agent: agent)

        _ ->
          if agent, do: assign(socket, focused_agent: agent), else: socket
      end
    else
      socket
    end
  end

  # --- Roster data helpers (for AgentRosterComponent) ---

  defp roster_agents(nil), do: []

  defp roster_agents(team_id) do
    parent_agents =
      case Loomkin.Teams.Manager.list_agents(team_id) do
        agents when is_list(agents) -> agents
        {:ok, agents} when is_list(agents) -> agents
        _other -> []
      end
      |> Enum.map(&Map.put(&1, :team_id, team_id))

    child_agents =
      team_id
      |> Loomkin.Teams.Manager.list_sub_teams()
      |> Enum.flat_map(fn child_id ->
        case Loomkin.Teams.Manager.list_agents(child_id) do
          agents when is_list(agents) -> agents
          {:ok, agents} when is_list(agents) -> agents
          _other -> []
        end
        |> Enum.map(&Map.put(&1, :team_id, child_id))
      end)

    parent_agents ++ child_agents
  end

  defp roster_agent_count(team_id), do: team_id |> roster_agents() |> length()

  defp roster_tasks(nil), do: []

  defp roster_tasks(team_id) do
    Loomkin.Teams.Tasks.list_all(team_id)
  end

  defp roster_budget(nil), do: %{spent: 0.0, limit: 5.0}

  defp roster_budget(team_id) do
    summary = Loomkin.Teams.CostTracker.team_cost_summary(team_id)

    spent =
      case summary[:total_cost_usd] do
        %Decimal{} = d -> Decimal.to_float(d)
        n when is_number(n) -> n / 1
        _ -> 0.0
      end

    %{spent: spent, limit: 5.0}
  end

  defp forward_to_team_components(socket) do
    forward_to_dashboard(socket)
  end

  defp forward_to_dashboard(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]

    if tid && team_tab_visible?(socket) do
      send_update(LoomkinWeb.TeamDashboardComponent, id: "team-dashboard", team_id: tid)
    end
  end

  defp forward_to_cost(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]

    if tid && team_tab_visible?(socket) && socket.assigns[:team_sub_tab] == :cost do
      try do
        send_update(LoomkinWeb.TeamCostComponent, id: "team-cost", team_id: tid)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp team_tab_visible?(socket),
    do: socket.assigns[:active_tab] == :team || socket.assigns[:mode] == :mission_control

  defp trackable_agent_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed in ["", "You", "system"] do
      nil
    else
      trimmed
    end
  end

  defp trackable_agent_name(_), do: nil

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

  # Map file extensions to highlight.js language names
  defp language_from_path(nil), do: "plaintext"

  defp language_from_path(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ".js" -> "javascript"
      ".json" -> "json"
      ext when ext in [".sh", ".bash", ".zsh"] -> "bash"
      ".css" -> "css"
      ext when ext in [".html", ".heex", ".leex"] -> "html"
      ".xml" -> "xml"
      ".md" -> "markdown"
      ext when ext in [".yml", ".yaml"] -> "yaml"
      ".diff" -> "diff"
      ".toml" -> "elixir"
      _ -> "plaintext"
    end
  end

  # --- Ask User helpers ---

  defp send_ask_user_answer(question_id, answer) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}) do
      [{pid, _}] ->
        send(pid, {:ask_user_answer, question_id, answer})

      [] ->
        Logger.warning("[AskUser] No waiting process for question #{question_id}")
    end
  end

  defp handle_collective_decision(question, _pending_questions) do
    team_id = question.team_id
    question_id = question.question_id
    options = question.options
    options_text = Enum.join(options, ", ")

    collective_prompt =
      "The human deferred this question to the collective. " <>
        "Question from #{question.agent_name}: #{question.question} " <>
        "Options: #{options_text}. " <>
        "Reply with ONLY your preferred option (exact text)."

    # Subscribe to the team topic to collect agent votes
    vote_topic = "ask_user:vote:#{question_id}"
    Phoenix.PubSub.subscribe(Loomkin.PubSub, vote_topic)

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{team_id}",
      {:peer_message, "system", collective_prompt,
       %{reply_topic: vote_topic, question_id: question_id, options: options}}
    )

    # Collect votes in a background task and deliver the result
    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      votes = collect_votes(vote_topic, options, 30_000)

      winner =
        if votes == [] do
          List.first(options) || "No consensus"
        else
          votes
          |> Enum.frequencies()
          |> Enum.max_by(fn {_opt, count} -> count end)
          |> elem(0)
        end

      send_ask_user_answer(question_id, "Collective: #{winner}")
      Phoenix.PubSub.unsubscribe(Loomkin.PubSub, vote_topic)
    end)
  end

  defp collect_votes(topic, valid_options, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_votes(topic, valid_options, deadline, [])
  end

  defp do_collect_votes(topic, valid_options, deadline, votes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      votes
    else
      receive do
        {:collective_vote, _agent, option} ->
          # Only count votes that match a valid option
          if option in valid_options do
            do_collect_votes(topic, valid_options, deadline, [option | votes])
          else
            do_collect_votes(topic, valid_options, deadline, votes)
          end
      after
        min(remaining, 1_000) ->
          do_collect_votes(topic, valid_options, deadline, votes)
      end
    end
  end

  # --- Command Palette ---

  defp build_palette_results(socket, query) do
    q = String.downcase(String.trim(query))
    team_id = socket.assigns[:active_team_id]

    agents =
      team_id
      |> roster_agents()
      |> Enum.map(fn a ->
        %{type: :agent, label: a[:name] || "unknown", detail: "Agent", value: a[:name] || ""}
      end)

    tabs =
      Enum.map([:files, :diff, :terminal, :graph, :chat], fn tab ->
        %{type: :tab, label: Atom.to_string(tab), detail: "Inspector Tab", value: Atom.to_string(tab)}
      end)

    sub_tabs =
      Enum.map([:activity, :cost, :graph], fn tab ->
        %{type: :sub_tab, label: Atom.to_string(tab), detail: "Team Sub-tab", value: Atom.to_string(tab)}
      end)

    actions = [
      %{type: :action, label: "Toggle Mode (Solo/Mission Control)", detail: "Action", value: "toggle_mode"},
      %{type: :action, label: "Focus Input", detail: "Action", value: "focus_input"}
    ]

    all = agents ++ tabs ++ sub_tabs ++ actions

    if q == "" do
      all
    else
      Enum.filter(all, fn item ->
        String.contains?(String.downcase(item.label), q) ||
          String.contains?(String.downcase(item.detail), q)
      end)
    end
  end

  defp render_command_palette(assigns) do
    ~H"""
    <div
      :if={@command_palette_open}
      class="fixed inset-0 z-50 flex items-start justify-center pt-[15vh]"
      phx-click="close_command_palette"
    >
      <div class="fixed inset-0 bg-black/60" />
      <div
        class="relative w-full max-w-lg bg-gray-900 border border-gray-700 rounded-xl shadow-2xl overflow-hidden"
        phx-click-away="close_command_palette"
        phx-hook="CommandPalette"
        id="command-palette"
      >
        <div class="flex items-center gap-2 px-4 py-3 border-b border-gray-800">
          <svg class="w-5 h-5 text-gray-500 flex-shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
          </svg>
          <input
            type="text"
            id="command-palette-input"
            placeholder="Search agents, tabs, actions..."
            value={@command_palette_query}
            phx-keyup="palette_search"
            name="query"
            class="flex-1 bg-transparent text-sm text-gray-100 placeholder-gray-500 outline-none"
            autocomplete="off"
            phx-debounce="100"
          />
          <kbd class="px-1.5 py-0.5 text-[10px] font-mono text-gray-500 bg-gray-800 rounded">Esc</kbd>
        </div>

        <div class="max-h-72 overflow-y-auto py-2">
          <div :if={@command_palette_results == []} class="px-4 py-6 text-center text-sm text-gray-500">
            No results found
          </div>
          <button
            :for={item <- @command_palette_results}
            data-palette-item
            phx-click="palette_select"
            phx-value-type={item.type}
            phx-value-value={item.value}
            class="flex items-center justify-between w-full px-4 py-2 text-left text-sm hover:bg-gray-800 focus:bg-gray-800 focus:outline-none transition-colors"
          >
            <div class="flex items-center gap-2 min-w-0">
              <span class={palette_icon_class(item.type)} />
              <span class="text-gray-200 truncate">{item.label}</span>
            </div>
            <span class="text-xs text-gray-500 flex-shrink-0 ml-2">{item.detail}</span>
          </button>
        </div>

        <div class="flex items-center gap-4 px-4 py-2 border-t border-gray-800 text-[10px] text-gray-600">
          <span>
            <kbd class="px-1 py-0.5 bg-gray-800 rounded font-mono">↑↓</kbd> navigate
          </span>
          <span>
            <kbd class="px-1 py-0.5 bg-gray-800 rounded font-mono">Enter</kbd> select
          </span>
          <span>
            <kbd class="px-1 py-0.5 bg-gray-800 rounded font-mono">Esc</kbd> close
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp palette_icon_class(:agent), do: "w-2 h-2 rounded-full bg-violet-400"
  defp palette_icon_class(:tab), do: "w-2 h-2 rounded-sm bg-blue-400"
  defp palette_icon_class(:sub_tab), do: "w-2 h-2 rounded-sm bg-emerald-400"
  defp palette_icon_class(:action), do: "w-2 h-2 rounded-full bg-amber-400"
  defp palette_icon_class(_), do: "w-2 h-2 rounded-full bg-gray-400"

end
