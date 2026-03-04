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
        collab_health: nil,
        # Channel bindings for the active team
        channel_bindings: [],
        # Track subscribed PubSub teams to prevent duplicate subscriptions
        subscribed_teams: MapSet.new(),
        # Agent picker for composer
        show_agent_picker: false,
        # Cached roster data (recomputed on roster_version changes, not per render)
        cached_agents: [],
        cached_tasks: [],
        cached_budget: %{spent: 0.0, limit: 5.0}
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

    Logger.debug("[WorkspaceLive] start_and_subscribe session=#{session_id} connected=#{connected?(socket)}")

    {:ok, pid} =
      Manager.start_session(
        session_id: session_id,
        model: socket.assigns.model,
        project_path: project_path,
        tools: tools,
        auto_approve: false
      )

    Logger.info("[WorkspaceLive] Session started pid=#{inspect(pid)}")

    # Read the effective model back from the session — for resumed sessions
    # this will be the DB-persisted model, not the mount default.
    effective_model =
      try do
        GenServer.call(pid, :get_model, 5_000)
      catch
        _, _ -> socket.assigns.model
      end

    socket =
      if connected?(socket) do
        Session.subscribe(session_id)
        Phoenix.PubSub.subscribe(Loomkin.PubSub, "telemetry:updates")
        Phoenix.PubSub.subscribe(Loomkin.PubSub, "auth:status")
        ensure_index_started(project_path)

        team_id = socket.assigns[:team_id]

        if team_id do
          socket = subscribe_to_team(socket, team_id)

          # Recover child teams from previous pageloads
          child_ids = Teams.Manager.list_sub_teams(team_id)
          Enum.reduce(child_ids, socket, &subscribe_to_team(&2, &1))
        else
          socket
        end
      else
        socket
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
    channel_bindings = load_channel_bindings(active_team_id)

    assign(socket,
      session_id: session_id,
      project_path: project_path,
      explorer_path: project_path,
      editing_explorer_path: false,
      model: effective_model,
      messages: messages,
      session_cost: session_metrics.cost_usd,
      session_tokens: session_metrics.prompt_tokens + session_metrics.completion_tokens,
      page_title: "Loomkin - #{short_id(session_id)}",
      child_teams: child_teams,
      active_team_id: active_team_id,
      switch_project_modal: nil,
      recent_projects: [],
      reply_target: nil,
      channel_bindings: channel_bindings
    )
  end

  # --- Events ---

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    trimmed = String.trim(text)

    case socket.assigns.reply_target do
      %{agent: agent_name, team_id: team_id} ->
        # Direct reply to a specific agent — validate agent still exists
        case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
          {:ok, pid} ->
            Task.start(fn -> Loomkin.Teams.Agent.send_message(pid, trimmed) end)

            reply_event = %{
              id: Ecto.UUID.generate(),
              type: :message,
              agent: "You",
              content: trimmed,
              timestamp: DateTime.utc_now(),
              expanded: false,
              metadata: %{from: "You", to: agent_name}
            }

            events = socket.assigns.activity_events ++ [reply_event]

            events =
              if length(events) > @max_activity_events,
                do: Enum.drop(events, length(events) - @max_activity_events),
                else: events

            {:noreply,
             socket
             |> assign(
               input_text: "",
               reply_target: nil,
               activity_events: events
             )
             |> push_event("clear-input", %{})}

          _ ->
            {:noreply,
             socket
             |> assign(reply_target: nil)
             |> put_flash(:warning, "Agent #{agent_name} is no longer available")
             |> push_event("clear-input", %{})}
        end

      nil ->
        # Normal flow: send through Architect pipeline
        session_id = socket.assigns.session_id
        Logger.info("[WorkspaceLive] Sending message via Architect session=#{session_id} mode=#{socket.assigns.mode} active_team_id=#{inspect(socket.assigns[:active_team_id])}")
        task = Task.async(fn -> Session.send_message(session_id, trimmed) end)

        user_msg = %{role: :user, content: trimmed}

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
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    Session.cancel(socket.assigns.session_id)
    {:noreply, assign(socket, status: :idle, streaming: false, streaming_content: "")}
  end

  def handle_event("reply_to_agent", %{"agent" => agent_name}, socket) do
    # Find the agent's team_id from the cached roster data
    agents = socket.assigns.cached_agents
    team_id = Enum.find_value(agents, socket.assigns.active_team_id, fn a ->
      if a.name == agent_name, do: a.team_id
    end)

    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, reply_target: nil)}
  end

  def handle_event("toggle_agent_picker", _params, socket) do
    {:noreply, assign(socket, show_agent_picker: !socket.assigns.show_agent_picker)}
  end

  def handle_event("select_reply_target", %{"agent" => agent_name, "team-id" => team_id}, socket) do
    {:noreply,
     assign(socket,
       reply_target: %{agent: agent_name, team_id: team_id},
       show_agent_picker: false
     )}
  end

  def handle_event("select_reply_target", %{"agent" => "team"}, socket) do
    {:noreply, assign(socket, reply_target: nil, show_agent_picker: false)}
  end

  def handle_event("close_agent_picker", _params, socket) do
    {:noreply, assign(socket, show_agent_picker: false)}
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
    bindings = load_channel_bindings(team_id)

    {:noreply,
     assign(socket, active_team_id: team_id, channel_bindings: bindings, reply_target: nil)}
  end

  def handle_event("edit_explorer_path", _params, socket) do
    {:noreply, assign(socket, editing_explorer_path: true)}
  end

  def handle_event("cancel_edit_explorer", _params, socket) do
    {:noreply, assign(socket, editing_explorer_path: false)}
  end

  def handle_event("set_explorer_path", %{"path" => path}, socket) do
    path = String.trim(path)

    if File.dir?(path) do
      {:noreply,
       socket
       |> assign(
         explorer_path: path,
         editing_explorer_path: false,
         file_tree_version: (socket.assigns[:file_tree_version] || 0) + 1
       )}
    else
      {:noreply,
       socket
       |> assign(editing_explorer_path: false)
       |> put_flash(:error, "Directory not found: #{path}")}
    end
  end

  def handle_event("toggle_mode", _, socket) do
    new_mode = if socket.assigns.mode == :solo, do: :mission_control, else: :solo
    {:noreply, assign(socket, mode: new_mode)}
  end

  def handle_event("initiate_switch_project", _params, socket) do
    {:noreply,
     assign(socket,
       switch_project_modal: %{
         phase: :input,
         target_path: socket.assigns.explorer_path,
         active_agents: []
       }
     )}
  end

  def handle_event("keyboard_shortcut", %{"key" => "toggle_mode"}, socket) do
    handle_event("toggle_mode", %{}, socket)
  end

  def handle_event("keyboard_shortcut", %{"key" => "cancel"}, socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("keyboard_shortcut", %{"key" => "escape"}, socket) do
    cond do
      socket.assigns.command_palette_open ->
        {:noreply,
         assign(socket,
           command_palette_open: false,
           command_palette_query: "",
           command_palette_results: []
         )}

      socket.assigns.show_agent_picker ->
        {:noreply, assign(socket, show_agent_picker: false)}

      true ->
        {:noreply,
         assign(socket,
           focused_agent: nil,
           inspector_mode: :auto_follow,
           permission_request: nil,
           reply_target: nil
         )}
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
    # Chat tab removed from inspector — ignore shortcut
    {:noreply, socket}
  end

  def handle_event("keyboard_shortcut", %{"key" => "jump_active_agent"}, socket) do
    agents = socket.assigns.cached_agents

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

    {:noreply, assign(socket, command_palette_query: query, command_palette_results: results)}
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

  @palette_valid_tabs ~w(files diff terminal graph)
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

  def handle_event("palette_select", %{"type" => "action", "value" => "switch_project"}, socket) do
    {:noreply,
     socket
     |> assign(
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: [],
       switch_project_modal: %{
         phase: :input,
         target_path: socket.assigns.explorer_path,
         active_agents: []
       }
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

  def handle_event("palette_select", %{"type" => "action", "value" => "refresh_channels"}, socket) do
    team_id = socket.assigns[:active_team_id]
    bindings = load_channel_bindings(team_id)

    {:noreply,
     assign(socket,
       channel_bindings: bindings,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
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

  # --- Component Info Messages ---

  def handle_info({:reply_to_agent, agent_name}, socket) do
    # Forwarded from roster component — same logic as the event handler
    agents = socket.assigns.cached_agents
    team_id = Enum.find_value(agents, socket.assigns.active_team_id, fn a ->
      if a.name == agent_name, do: a.team_id
    end)

    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
  end

  # --- PubSub Info ---

  def handle_info({:new_message, _session_id, %{role: :user}}, socket) do
    # User messages are added optimistically in handle_event — skip PubSub duplicate
    {:noreply, socket}
  end

  def handle_info({:new_message, _session_id, msg}, socket) do
    Logger.info("[WorkspaceLive] :new_message role=#{msg.role} content_len=#{String.length(msg.content || "")}")
    socket = assign(socket, messages: socket.assigns.messages ++ [msg])

    # Also add assistant messages to activity feed for mission control mode
    socket =
      if msg.role == :assistant do
        event = %{
          id: Ecto.UUID.generate(),
          type: :message,
          agent: "Architect",
          content: msg.content,
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: %{from: "Architect", role: :assistant}
        }

        append_activity_event(socket, event)
      else
        socket
      end

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
    Logger.info("[WorkspaceLive] :tool_executing source=#{inspect(source)} tool=#{name}")
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
    Logger.info("[WorkspaceLive] :team_available received team_id=#{team_id}")
    bindings = load_channel_bindings(team_id)

    socket =
      socket
      |> subscribe_to_team(team_id)
      |> assign(team_id: team_id, active_team_id: team_id, mode: :mission_control, channel_bindings: bindings)
      |> refresh_roster()

    {:noreply, socket}
  end

  def handle_info({:child_team_available, _session_id, child_team_id}, socket) do
    Logger.info("[WorkspaceLive] :child_team_available child_team_id=#{child_team_id}")
    socket = subscribe_to_team(socket, child_team_id)

    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    socket =
      socket
      |> assign(child_teams: child_teams, mode: :mission_control)
      |> update(:roster_version, &((&1 || 0) + 1))
      |> refresh_roster()

    {:noreply, socket}
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
    Logger.info("[WorkspaceLive] :architect_phase phase=#{phase}")
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
    abs_path = Path.join(socket.assigns.explorer_path, path)

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

  # --- Switch Project modal messages ---

  def handle_info({:switch_project_set_path, path}, socket) do
    if !File.dir?(path) do
      {:noreply, put_flash(socket, :error, "Directory not found: #{path}")}
    else
      team_id = socket.assigns[:team_id]
      # Include sub-team agents so we don't skip confirmation while child agents are running
      agents = if team_id, do: Teams.Manager.list_all_agents(team_id), else: []
      active = Enum.filter(agents, fn a -> a.status not in [:idle] end)

      if active == [] do
        {:noreply, do_switch_project(socket, path)}
      else
        {:noreply,
         assign(socket,
           switch_project_modal: %{
             phase: :confirm,
             target_path: path,
             active_agents: active
           }
         )}
      end
    end
  end

  def handle_info(:cancel_switch_project, socket) do
    {:noreply, assign(socket, switch_project_modal: nil)}
  end

  def handle_info(:confirm_switch_project, socket) do
    modal = socket.assigns.switch_project_modal

    if modal do
      team_id = socket.assigns[:team_id]
      if team_id, do: Teams.Manager.cancel_all_loops(team_id)
      {:noreply, do_switch_project(socket, modal.target_path)}
    else
      {:noreply, socket}
    end
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
  def handle_info({:agent_status, agent_name, status} = event, socket) do
    Logger.debug("[WorkspaceLive] :agent_status agent=#{agent_name} status=#{status}")
    forward_to_team_components(socket)

    socket =
      socket
      |> update(:roster_version, &((&1 || 0) + 1))
      |> refresh_roster()

    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_created, _task_id, _title} = event, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket |> refresh_roster() |> forward_to_activity(event)}
  end

  def handle_info({:task_assigned, _task_id, _agent_name} = event, socket) do
    forward_to_dashboard(socket)
    {:noreply, socket |> refresh_roster() |> forward_to_activity(event)}
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
    child_teams =
      if child_team_id in socket.assigns.child_teams do
        socket.assigns.child_teams
      else
        socket.assigns.child_teams ++ [child_team_id]
      end

    socket =
      socket
      |> subscribe_to_team(child_team_id)
      |> assign(:child_teams, child_teams)
      |> update(:roster_version, &((&1 || 0) + 1))
      |> refresh_roster()

    {:noreply, socket}
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
        {:ok, response} ->
          Logger.info("[WorkspaceLive] Async task completed OK response=#{inspect(response, limit: 200)}")
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

  # Forwarded from AgentRosterComponent reply button
  def handle_info({:reply_to_agent, agent_name, team_id}, socket) do
    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
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

  # Channel messages — inbound/outbound activity from Bridge
  def handle_info({:channel_message, payload}, socket) do
    direction = Map.get(payload, :direction, :inbound)
    channel = Map.get(payload, :channel, :unknown)
    text = Map.get(payload, :text, "")
    agent_name = Map.get(payload, :agent_name)

    channel_label = channel |> to_string() |> String.capitalize()

    {content, event_agent} =
      case direction do
        :inbound ->
          {"[#{channel_label}] Incoming: #{String.slice(text, 0, 150)}", channel_label}

        :outbound ->
          {"[#{channel_label}] Sent by #{agent_name || "agent"}", agent_name || channel_label}
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :channel_message,
      agent: event_agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{channel: channel, direction: direction}
    }

    {:noreply, append_activity_event(socket, event)}
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

  # OAuth auth status changed — refresh model selector to reflect new provider availability
  def handle_info({:auth_connected, _provider}, socket) do
    {:noreply, send_update_to_model_selector(socket)}
  end

  def handle_info({:auth_disconnected, _provider}, socket) do
    {:noreply, send_update_to_model_selector(socket)}
  end

  def handle_info({:auth_refreshed, _provider}, socket) do
    {:noreply, socket}
  end

  def handle_info({:auth_refresh_failed, _provider, _reason}, socket) do
    {:noreply, send_update_to_model_selector(socket)}
  end

  # Catch-all for unhandled PubSub messages (team events, etc.)
  def handle_info(msg, socket) do
    Logger.info("[WorkspaceLive] UNHANDLED message: #{inspect(msg, limit: 200)}")
    {:noreply, socket}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div
      class="flex flex-col h-screen overflow-hidden bg-surface-0 gradient-mesh text-gray-100"
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

      <%!-- Switch Project modal overlay --%>
      <.live_component
        :if={@switch_project_modal}
        module={LoomkinWeb.SwitchProjectComponent}
        id="switch-project-modal"
        modal={@switch_project_modal}
        explorer_path={@explorer_path}
        recent_projects={@recent_projects}
      />

      <%!-- Command palette overlay --%>
      {render_command_palette(assigns)}

      <%!-- ── Header ── --%>
      <header
        class="flex-shrink-0 flex items-center gap-2 px-3 py-2 sm:px-4 lg:px-5 relative"
        style="background: var(--surface-1); border-bottom: 1px solid var(--border-subtle); z-index: 50;"
      >
        <%!-- Brand mark --%>
        <a href="/" class="flex items-center gap-2 flex-shrink-0 group mr-1">
          <svg class="w-5 h-5 transition-transform duration-200 group-hover:scale-110" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
            <polygon points="10,2 6,10 15,7" fill="#5B21B6" />
            <polygon points="22,2 26,10 17,7" fill="#5B21B6" />
            <polygon points="6,10 4,20 12,15" fill="#4B0082" />
            <polygon points="26,10 28,20 20,15" fill="#4B0082" />
            <polygon points="12,15 16,7 20,15" fill="#7C3AED" />
            <polygon points="12,15 16,24 20,15" fill="#4B0082" />
            <circle cx="12" cy="14" r="3" fill="#F59E0B" />
            <circle cx="20" cy="14" r="3" fill="#F59E0B" />
          </svg>
          <span class="text-sm font-semibold bg-gradient-to-r from-violet-400 to-purple-400 bg-clip-text text-transparent tracking-tight hidden sm:inline">
            Loomkin
          </span>
        </a>

        <%!-- Separator --%>
        <div class="hidden sm:block w-px h-4 flex-shrink-0" style="background: var(--border-default);"></div>

        <%!-- Model selector --%>
        <.live_component
          module={LoomkinWeb.ModelSelectorComponent}
          id="model-selector"
          model={@model}
        />

        <%!-- Separator --%>
        <div class="hidden md:block w-px h-4 flex-shrink-0" style="background: var(--border-default);"></div>

        <%!-- Project pill --%>
        <button
          phx-click="initiate_switch_project"
          class="hidden md:flex items-center gap-1.5 px-2 py-1 rounded-md text-xs interactive press-down"
          style="color: var(--text-secondary);"
          title={@project_path}
        >
          <span class="relative flex h-1.5 w-1.5 flex-shrink-0">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-40"></span>
            <span class="relative inline-flex rounded-full h-1.5 w-1.5 bg-emerald-500"></span>
          </span>
          <span class="font-mono truncate max-w-[8rem]">{Path.basename(@project_path)}</span>
        </button>

        <%!-- Team indicator (mission control mode) --%>
        <div
          :if={@mode == :mission_control && @active_team_id}
          class="hidden md:flex items-center gap-1.5"
        >
          <div class="w-px h-4 flex-shrink-0" style="background: var(--border-default);"></div>
          <div class="flex items-center gap-1.5 px-2 py-1 rounded-md" style="background: var(--brand-subtle);">
            <span style="color: var(--text-brand);"><.icon name="hero-user-group-mini" class="w-3 h-3" /></span>
            <span class="text-xs font-medium" style="color: var(--text-brand);">
              {short_team_id(@active_team_id)}
            </span>
            <span class="text-[10px]" style="color: var(--text-muted);">
              {length(@cached_agents)}
            </span>
          </div>

          {render_header_channel_badges(assigns)}
          <select
            :if={@child_teams != []}
            phx-change="switch_team"
            name="team-id"
            class="max-w-[8rem] truncate text-xs rounded-md px-2 py-1 focus:outline-none"
            style="background: var(--surface-2); border: 1px solid var(--border-subtle); color: var(--text-secondary);"
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

        <%!-- Spacer --%>
        <div class="flex-1"></div>

        <%!-- Right: Controls --%>
        <div class="flex items-center gap-1.5">
          <%!-- Cost pill --%>
          <a
            href="/dashboard"
            class="flex items-center gap-1.5 rounded-md px-2 py-1 text-xs transition-all duration-200 interactive"
            style="color: var(--text-muted);"
            title="View dashboard"
          >
            <span style="color: var(--text-brand); opacity: 0.7;"><.icon name="hero-sparkles-mini" class="w-3 h-3" /></span>
            <span class="font-mono" style="color: var(--text-secondary);">${format_cost(@session_cost)}</span>
            <span class="hidden font-mono sm:inline" style="color: var(--text-muted); font-size: 10px;">
              {format_tokens(@session_tokens)}t
            </span>
          </a>

          <%!-- Separator --%>
          <div class="w-px h-4 flex-shrink-0" style="background: var(--border-default);"></div>

          <%!-- Session switcher --%>
          <.live_component
            module={LoomkinWeb.SessionSwitcherComponent}
            id="session-switcher"
            session_id={@session_id}
          />

          <%!-- Status pill --%>
          <div class={status_badge_class(@status)}>
            <span class={status_dot_class(@status)} />
            <span class="hidden sm:inline">{status_label(@status, @current_tool_name)}</span>
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
    <div class="flex-1 flex flex-col min-w-0 min-h-0 bg-surface-0">
      <div class="flex-1 overflow-auto min-h-0">
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
      </div>

      <%!-- Pending ask_user questions (also shown in solo mode) --%>
      <div :if={@pending_questions != []} class="flex-shrink-0 px-3 py-2" style="border-top: 1px solid var(--border-brand); background: var(--surface-1);">
        <.live_component
          module={LoomkinWeb.AskUserComponent}
          id="ask-user-questions-solo"
          questions={@pending_questions}
        />
      </div>

      {render_input_bar(assigns)}
    </div>

    <%!-- Right: Sidebar --%>
    <div class="h-[20rem] w-full flex flex-col xl:h-auto xl:w-80 bg-surface-1" style="border-top: 1px solid var(--border-subtle);">
      <%!-- Sidebar tab bar --%>
      <div class="flex items-center gap-0.5 px-1.5 py-1 overflow-x-auto flex-shrink-0" style="border-bottom: 1px solid var(--border-subtle);">
        <button
          :for={tab <- [:files, :diff, :terminal, :graph]}
          phx-click="switch_tab"
          phx-value-tab={tab}
          class={"relative flex items-center gap-1 px-2 py-1.5 text-[11px] font-medium rounded-md transition-all duration-200 interactive " <>
            if(@active_tab == tab,
              do: "text-brand after:absolute after:bottom-0 after:left-1 after:right-1 after:h-[1.5px] after:rounded-full after:bg-violet-500",
              else: "text-muted")}
        >
          <span>{tab_icon(tab)}</span>
          <span class="text-[10px]">{tab_label(tab)}</span>
        </button>
      </div>

      <%!-- Sidebar content --%>
      <div
        class="flex-1 overflow-auto p-3 tab-content-enter"
        style="background: var(--surface-0);"
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
    <%!-- Left: Agent Roster (xl:w-64) --%>
    <.live_component
      module={LoomkinWeb.AgentRosterComponent}
      id="agent-roster"
      team_id={@active_team_id}
      agents={@cached_agents}
      tasks={@cached_tasks}
      budget={@cached_budget}
      focused_agent={@focused_agent}
      roster_version={@roster_version}
      channel_bindings={@channel_bindings}
    />

    <%!-- Center: Activity Feed (flex-1) + Composer --%>
    <div class="flex-1 flex flex-col min-w-0 min-h-0 bg-surface-0" style="border-left: 1px solid var(--border-subtle); border-right: 1px solid var(--border-subtle);">
      <%!-- Scrollable feed area --%>
      <div class="flex-1 overflow-auto min-h-0">
        <.live_component
          module={LoomkinWeb.TeamActivityComponent}
          id="activity-feed"
          team_id={@active_team_id}
          events={filter_high_signal_events(@activity_events)}
          known_agents={@activity_known_agents}
          focused_agent={@focused_agent}
        />
      </div>

      <%!-- Pending ask_user questions --%>
      <div :if={@pending_questions != []} class="flex-shrink-0 px-3 py-2" style="border-top: 1px solid var(--border-brand); background: var(--surface-1);">
        <.live_component
          module={LoomkinWeb.AskUserComponent}
          id="ask-user-questions"
          questions={@pending_questions}
        />
      </div>

      <%!-- Collapsible tool calls feed --%>
      <div class="flex-shrink-0">
        <.live_component
          module={LoomkinWeb.ToolCallsComponent}
          id="tool-calls-feed"
          events={@activity_events}
        />
      </div>

      <%!-- Sticky composer --%>
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
      project_path={@explorer_path}
    />
    """
  end

  # --- Shared input bar (used by both modes) ---

  defp render_input_bar(assigns) do
    agents = assigns[:cached_agents] || []
    assigns = assign(assigns, :picker_agents, agents)

    ~H"""
    <div class="flex-shrink-0" style="background: var(--surface-1); border-top: 1px solid var(--border-subtle);">
      <form phx-submit="send_message" class="px-3 py-2.5 sm:px-4 sm:py-3">
        <%!-- Reply indicator --%>
        <div
          :if={@reply_target}
          class="flex items-center gap-2 mb-2 px-2.5 py-1.5 rounded-lg animate-fade-in"
          style="background: var(--brand-subtle); border: 1px solid var(--border-brand);"
        >
          <span class="badge" style="padding: 1px 6px; font-size: 10px;">
            {@reply_target.agent}
          </span>
          <span class="text-[11px]" style="color: var(--text-muted);">Replying</span>
          <button
            type="button"
            phx-click="cancel_reply"
            class="ml-auto rounded-full p-0.5 transition-colors interactive"
            style="color: var(--text-muted);"
          >
            <.icon name="hero-x-mark-mini" class="w-3 h-3" />
          </button>
        </div>

        <div class="flex gap-1.5 items-end">
          <%!-- Agent picker button --%>
          <div class="relative flex-shrink-0">
            <button
              type="button"
              phx-click="toggle_agent_picker"
              class="flex items-center justify-center h-9 px-2 rounded-lg transition-all duration-200 press-down"
              style={"border: 1px solid " <> if(@reply_target, do: "var(--border-brand)", else: "var(--border-subtle)") <> "; color: " <> if(@reply_target, do: "var(--text-brand)", else: "var(--text-muted)") <> "; background: transparent;"}
              title={if @reply_target, do: @reply_target.agent, else: "Send to team"}
            >
              <.icon name="hero-at-symbol-mini" class="w-3.5 h-3.5" />
              <span :if={@reply_target} class="text-[11px] font-medium ml-1 max-w-[4rem] truncate">{@reply_target.agent}</span>
            </button>

            <%!-- Agent picker dropdown --%>
            <div
              :if={@show_agent_picker}
              class="card-elevated absolute bottom-full left-0 mb-2 w-52 max-h-60 overflow-y-auto py-1 z-50 animate-scale-in"
              phx-click-away="close_agent_picker"
            >
              <div class="px-2.5 py-1.5" style="border-bottom: 1px solid var(--border-subtle);">
                <span class="text-[10px] font-medium uppercase tracking-wider" style="color: var(--text-muted);">Send to</span>
              </div>
              <button
                type="button"
                phx-click="select_reply_target"
                phx-value-agent="team"
                class={"flex items-center gap-2 w-full px-2.5 py-1.5 text-left text-xs transition-colors interactive " <> if(!@reply_target, do: "bg-surface-3", else: "")}
                style="color: var(--text-primary);"
              >
                <span class="w-1.5 h-1.5 rounded-full flex-shrink-0 bg-emerald-400" />
                <span class="font-medium">Entire Team</span>
              </button>
              <button
                :for={agent <- @picker_agents}
                type="button"
                phx-click="select_reply_target"
                phx-value-agent={agent.name}
                phx-value-team-id={agent.team_id}
                class={"flex items-center gap-2 w-full px-2.5 py-1.5 text-left text-xs transition-colors interactive " <> if(@reply_target && @reply_target.agent == agent.name, do: "bg-surface-3", else: "")}
              >
                <span class={"w-1.5 h-1.5 rounded-full flex-shrink-0 " <> agent_picker_dot_class(agent[:status])} />
                <span class="truncate" style={"color: #{agent_color(agent.name)};"}>{agent.name}</span>
                <span class="ml-auto text-[10px]" style="color: var(--text-muted);">{agent[:role] || agent[:status]}</span>
              </button>
            </div>
          </div>

          <%!-- Textarea --%>
          <div class="flex-1 relative">
            <textarea
              name="text"
              rows="1"
              placeholder={if @reply_target, do: "Reply to #{@reply_target.agent}...", else: "What should we work on?"}
              class="w-full rounded-lg px-3 py-2 text-sm resize-none focus:outline-none transition-all duration-200"
              style="background: var(--surface-0); border: 1px solid var(--border-subtle); color: var(--text-primary); caret-color: var(--brand);"
              onfocus="this.style.borderColor='var(--border-brand)'; this.style.boxShadow='0 0 0 1px rgba(124, 58, 237, 0.2)';"
              onblur="this.style.borderColor='var(--border-subtle)'; this.style.boxShadow='none';"
              phx-hook="ShiftEnterSubmit"
              id="message-input"
            ><%= @input_text %></textarea>
          </div>

          <%!-- Send/Cancel buttons --%>
          <button
            :if={@status != :thinking}
            type="submit"
            class={"flex items-center justify-center w-9 h-9 rounded-lg transition-all duration-200 press-down " <>
              if(@status == :idle, do: "text-white", else: "cursor-not-allowed")}
            style={if @status == :idle, do: "background: var(--brand);", else: "background: var(--surface-2); color: var(--text-muted);"}
            disabled={@status != :idle}
          >
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5" />
            </svg>
          </button>
          <button
            :if={@status == :thinking}
            type="button"
            phx-click="cancel"
            class="flex items-center justify-center w-9 h-9 rounded-lg transition-all duration-200 press-down"
            style="background: rgba(248, 113, 113, 0.15); color: #f87171; border: 1px solid rgba(248, 113, 113, 0.3);"
          >
            <svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
              <rect x="6" y="6" width="12" height="12" rx="2" />
            </svg>
          </button>
        </div>

        <div class="flex items-center gap-3 mt-1 pl-0.5">
          <span class="text-[10px]" style="color: var(--text-muted); opacity: 0.6;">
            <kbd class="font-mono text-[9px]">&#8679;&#9166;</kbd> new line
          </span>
          <span class="text-[10px]" style="color: var(--text-muted); opacity: 0.6;">
            <kbd class="font-mono text-[9px]">/</kbd> focus
          </span>
        </div>
      </form>
    </div>
    """
  end

  # --- Helpers ---

  defp status_badge_class(:idle), do: "badge-success flex items-center gap-1.5"
  defp status_badge_class(:thinking), do: "badge flex items-center gap-1.5"
  defp status_badge_class(:executing_tool), do: "badge flex items-center gap-1.5"
  defp status_badge_class(_), do: "badge flex items-center gap-1.5"

  defp status_dot_class(:idle), do: "w-1.5 h-1.5 rounded-full bg-emerald-400 status-dot-idle"
  defp status_dot_class(:thinking), do: "w-1.5 h-1.5 rounded-full bg-violet-400 status-dot-thinking"
  defp status_dot_class(:executing_tool), do: "w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse"
  defp status_dot_class(_), do: "w-1.5 h-1.5 rounded-full bg-zinc-500"

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
          project_path={assigns[:explorer_path] || assigns[:project_path] || File.cwd!()}
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
        <span
          :if={@collab_health}
          class="ml-auto flex items-center gap-1 text-xs"
          title={"Collaboration health: #{@collab_health}/100"}
        >
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

  # Subscribe to a team's PubSub topics, but only once per team.
  # Returns the updated socket with the team tracked in :subscribed_teams.
  defp subscribe_to_team(socket, team_id) do
    subscribed = socket.assigns[:subscribed_teams] || MapSet.new()

    if MapSet.member?(subscribed, team_id) do
      socket
    else
      Logger.info("[WorkspaceLive] subscribe_to_team(#{team_id}) self=#{inspect(self())}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:tasks")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:context")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:decisions")
      assign(socket, subscribed_teams: MapSet.put(subscribed, team_id))
    end
  end

  defp send_update_to_model_selector(socket) do
    # Bump auth_version so the component knows to reload providers,
    # even when the model string hasn't changed
    auth_version = (socket.assigns[:auth_version] || 0) + 1

    send_update(LoomkinWeb.ModelSelectorComponent,
      id: "model-selector",
      model: socket.assigns.model,
      auth_version: auth_version
    )

    assign(socket, auth_version: auth_version)
  end

  # Recompute cached roster data.
  # Called when roster_version bumps — avoids per-render Registry queries.
  # NOTE: Do NOT subscribe to PubSub topics here — this is called from many
  # event handlers and PubSub.subscribe is not idempotent (each call adds
  # another subscription, causing duplicate event delivery).
  defp refresh_roster(socket) do
    team_id = socket.assigns[:active_team_id]
    agents = roster_agents(team_id)
    tasks = roster_tasks(team_id)
    budget = roster_budget(team_id)

    assign(socket, cached_agents: agents, cached_tasks: tasks, cached_budget: budget)
  end

  defp forward_to_activity(socket, pubsub_event) do
    case activity_event_from(pubsub_event) do
      nil ->
        Logger.debug("[WorkspaceLive] forward_to_activity: DROPPED event=#{inspect(elem(pubsub_event, 0))}")
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

    # team_assign results are converted into structured task cards
    if tool_name == "team_assign" do
      merge_team_assign_result(socket, agent, result_str)
    else
      merge_generic_tool_result(socket, agent, tool_name, result_str)
    end
  end

  defp merge_tool_result(socket, _), do: socket

  defp merge_team_assign_result(socket, agent, result_str) do
    task_meta = parse_team_assign_result(result_str)
    events = socket.assigns.activity_events

    # Replace the pending team_assign tool_call card with a typed task_assigned card
    match_idx =
      events
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {ev, idx} ->
        if ev.type == :tool_call && ev.agent == agent &&
             (ev.metadata || %{})[:tool_name] == "team_assign" &&
             is_nil((ev.metadata || %{})[:result]) do
          idx
        end
      end)

    events =
      if match_idx do
        List.update_at(events, match_idx, fn ev ->
          %{
            ev
            | type: :task_assigned,
              content: "Assigned task to #{task_meta[:owner] || "agent"}",
              metadata: task_meta
          }
        end)
      else
        events ++
          [
            %{
              id: Ecto.UUID.generate(),
              type: :task_assigned,
              agent: agent,
              content: "Assigned task to #{task_meta[:owner] || "agent"}",
              timestamp: DateTime.utc_now(),
              expanded: false,
              metadata: task_meta
            }
          ]
      end

    assign(socket, activity_events: events)
  end

  defp parse_team_assign_result(result_str) do
    extract = fn key ->
      case Regex.run(~r/#{key}:\s*(.+)/i, result_str) do
        [_, value] -> String.trim(value)
        _ -> nil
      end
    end

    %{
      title: extract.("Title"),
      owner: extract.("Assigned to"),
      priority: extract.("Priority"),
      status: extract.("Status")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp merge_generic_tool_result(socket, agent, tool_name, result_str) do
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

  # --- Agent status: surface spawn and working transitions ---

  defp activity_event_from({:agent_status, agent, :idle}) do
    # Agent just spawned (initial status broadcast) — show as spawn event
    %{
      id: Ecto.UUID.generate(),
      type: :agent_spawn,
      agent: agent,
      content: "#{agent} joined",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{agent_name: agent}
    }
  end

  defp activity_event_from({:agent_status, agent, :working}) do
    %{
      id: Ecto.UUID.generate(),
      type: :status,
      agent: agent,
      content: "Started working",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

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

  defp activity_event_from({:task_created, _task_id, title}) do
    %{
      id: Ecto.UUID.generate(),
      type: :task_created,
      agent: "system",
      content: "New task created",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{title: title}
    }
  end

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
        :consensus_success -> :decision
        :consensus_deadlock -> :error
        :consensus_escalation -> :error
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

  # Filter out low-signal events from the primary activity feed.
  # Tool calls and context offloads go to the collapsible ToolCallsComponent instead.
  @low_signal_event_types [:tool_call, :context_offload]

  defp filter_high_signal_events(events) do
    Enum.reject(events, fn event -> event.type in @low_signal_event_types end)
  end

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
    all_parent =
      case Loomkin.Teams.Manager.list_agents(team_id) do
        agents when is_list(agents) -> agents
        {:ok, agents} when is_list(agents) -> agents
        _other -> []
      end

    parent_agents =
      all_parent
      |> Enum.map(&Map.put(&1, :team_id, team_id))
      |> Enum.reject(fn a -> a.name == "lead" end)

    sub_teams = Loomkin.Teams.Manager.list_sub_teams(team_id)

    child_agents =
      sub_teams
      |> Enum.flat_map(fn child_id ->
        case Loomkin.Teams.Manager.list_agents(child_id) do
          agents when is_list(agents) -> agents
          {:ok, agents} when is_list(agents) -> agents
          _other -> []
        end
        |> Enum.map(&Map.put(&1, :team_id, child_id))
      end)

    result = parent_agents ++ child_agents
    # Debug-level logging removed — roster_agents is now cached and called less frequently
    result
  end

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

  defp agent_picker_dot_class(:idle), do: "bg-green-400"
  defp agent_picker_dot_class(:thinking), do: "bg-violet-400 status-dot-thinking"
  defp agent_picker_dot_class(:executing_tool), do: "bg-blue-400"
  defp agent_picker_dot_class(:error), do: "bg-red-400"
  defp agent_picker_dot_class(:blocked), do: "bg-amber-400"
  defp agent_picker_dot_class(_), do: "bg-gray-400"

  @agent_colors [
    "#818cf8", "#f472b6", "#34d399", "#fb923c", "#22d3ee",
    "#a78bfa", "#fbbf24", "#f87171", "#4ade80", "#60a5fa"
  ]

  defp agent_color(name) when is_binary(name) do
    idx = :erlang.phash2(name, length(@agent_colors))
    Enum.at(@agent_colors, idx)
  end

  defp agent_color(_), do: "#a1a1aa"

  defp short_team_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_team_id(_), do: "?"

  defp do_switch_project(socket, path) do
    team_id = socket.assigns[:team_id]

    if team_id do
      Teams.Manager.update_project_path(team_id, path)
    end

    # Update the Session GenServer so the Architect uses the new path
    Session.update_project_path(socket.assigns.session_id, path)

    # Track in recent projects (dedup, max 5)
    recent =
      [socket.assigns.project_path | socket.assigns.recent_projects]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == path))
      |> Enum.take(5)

    socket
    |> assign(
      project_path: path,
      explorer_path: path,
      switch_project_modal: nil,
      file_tree_version: (socket.assigns[:file_tree_version] || 0) + 1,
      recent_projects: recent
    )
  end

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

    agents =
      (socket.assigns[:cached_agents] || [])
      |> Enum.map(fn a ->
        %{type: :agent, label: a[:name] || "unknown", detail: "Agent", value: a[:name] || ""}
      end)

    tabs =
      Enum.map([:files, :diff, :terminal, :graph], fn tab ->
        %{
          type: :tab,
          label: Atom.to_string(tab),
          detail: "Inspector Tab",
          value: Atom.to_string(tab)
        }
      end)

    sub_tabs =
      Enum.map([:activity, :cost, :graph], fn tab ->
        %{
          type: :sub_tab,
          label: Atom.to_string(tab),
          detail: "Team Sub-tab",
          value: Atom.to_string(tab)
        }
      end)

    actions = [
      %{
        type: :action,
        label: "Toggle Mode (Solo/Mission Control)",
        detail: "Action",
        value: "toggle_mode"
      },
      %{type: :action, label: "Switch Project", detail: "Action", value: "switch_project"},
      %{type: :action, label: "Focus Input", detail: "Action", value: "focus_input"},
      %{
        type: :action,
        label: "Refresh Channel Bindings",
        detail: "Channels",
        value: "refresh_channels"
      }
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
        class="relative w-full max-w-lg card-elevated overflow-hidden"
        style="box-shadow: 0 16px 64px rgba(0,0,0,0.6), 0 0 0 1px var(--border-default);"
        phx-click-away="close_command_palette"
        phx-hook="CommandPalette"
        id="command-palette"
      >
        <div class="flex items-center gap-2 px-4 py-3" style="border-bottom: 1px solid var(--border-subtle);">
          <svg class="w-4 h-4 flex-shrink-0" style="color: var(--text-muted);" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
          </svg>
          <input
            type="text"
            id="command-palette-input"
            placeholder="Search agents, tabs, actions..."
            value={@command_palette_query}
            phx-keyup="palette_search"
            name="query"
            class="flex-1 bg-transparent text-sm outline-none"
            style="color: var(--text-primary); caret-color: var(--brand);"
            autocomplete="off"
            phx-debounce="100"
          />
          <kbd class="px-1.5 py-0.5 text-[10px] font-mono rounded" style="background: var(--surface-2); color: var(--text-muted);">Esc</kbd>
        </div>

        <div class="max-h-72 overflow-y-auto py-1">
          <div :if={@command_palette_results == []} class="px-4 py-6 text-center text-sm" style="color: var(--text-muted);">
            No results found
          </div>
          <button
            :for={item <- @command_palette_results}
            data-palette-item
            phx-click="palette_select"
            phx-value-type={item.type}
            phx-value-value={item.value}
            class="flex items-center justify-between w-full px-4 py-2 text-left text-sm transition-colors interactive"
          >
            <div class="flex items-center gap-2 min-w-0">
              <span class={palette_icon_class(item.type)} />
              <span class="truncate" style="color: var(--text-secondary);">{item.label}</span>
            </div>
            <span class="text-xs flex-shrink-0 ml-2" style="color: var(--text-muted);">{item.detail}</span>
          </button>
        </div>

        <div class="flex items-center gap-4 px-4 py-2 text-[10px]" style="border-top: 1px solid var(--border-subtle); color: var(--text-muted); opacity: 0.7;">
          <span>
            <kbd class="px-1 py-0.5 rounded font-mono" style="background: var(--surface-2);">↑↓</kbd> navigate
          </span>
          <span>
            <kbd class="px-1 py-0.5 rounded font-mono" style="background: var(--surface-2);">Enter</kbd> select
          </span>
          <span>
            <kbd class="px-1 py-0.5 rounded font-mono" style="background: var(--surface-2);">Esc</kbd> close
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

  # --- Channel binding helpers ---

  defp render_header_channel_badges(assigns) do
    telegram = Enum.count(assigns.channel_bindings, &(&1.channel == :telegram))
    discord = Enum.count(assigns.channel_bindings, &(&1.channel == :discord))

    assigns =
      assigns
      |> assign(:telegram_count, telegram)
      |> assign(:discord_count, discord)

    ~H"""
    <span
      :if={@telegram_count > 0}
      class="inline-flex items-center gap-0.5 text-[10px] text-sky-400 bg-sky-400/10 px-1.5 py-0.5 rounded-full"
      title={"#{@telegram_count} Telegram"}
    >
      <svg class="w-3 h-3" viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z" />
      </svg>
    </span>
    <span
      :if={@discord_count > 0}
      class="inline-flex items-center gap-0.5 text-[10px] text-indigo-400 bg-indigo-400/10 px-1.5 py-0.5 rounded-full"
      title={"#{@discord_count} Discord"}
    >
      <svg class="w-3 h-3" viewBox="0 0 24 24" fill="currentColor">
        <path d="M20.317 4.37a19.791 19.791 0 00-4.885-1.515.074.074 0 00-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 00-5.487 0 12.64 12.64 0 00-.617-1.25.077.077 0 00-.079-.037A19.736 19.736 0 003.677 4.37a.07.07 0 00-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 00.031.057 19.9 19.9 0 005.993 3.03.078.078 0 00.084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 00-.041-.106 13.107 13.107 0 01-1.872-.892.077.077 0 01-.008-.128 10.2 10.2 0 00.372-.292.074.074 0 01.077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 01.078.01c.12.098.246.198.373.292a.077.077 0 01-.006.127 12.299 12.299 0 01-1.873.892.077.077 0 00-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 00.084.028 19.839 19.839 0 006.002-3.03.077.077 0 00.032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 00-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
      </svg>
    </span>
    """
  end

  defp load_channel_bindings(nil), do: []

  defp load_channel_bindings(team_id) do
    try do
      Loomkin.Channels.Bindings.list_bindings_for_team(team_id)
    rescue
      _ -> []
    end
  end
end
