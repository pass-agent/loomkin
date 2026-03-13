defmodule LoomkinWeb.WorkspaceLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Session
  alias Loomkin.Session.Manager
  alias Loomkin.Teams
  alias Loomkin.Teams.TeamBroadcaster
  alias Loomkin.Teams.Topics

  @max_messages 200
  @max_diffs 100
  @roster_debounce_ms 50

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
        pending_permissions: [],
        page_title: "Loomkin Workspace",
        team_id: params["team_id"],
        team_tree: %{},
        team_names: %{},
        active_team_id: params["team_id"],
        team_sub_tab: :activity,
        streaming: false,
        streaming_content: "",
        streaming_agent: nil,
        architect_phase: nil,
        plan_steps: [],
        current_step: nil,
        activity_known_agents: [],
        activity_event_count: 0,
        buffered_activity_events: [],
        # Map of {agent, tool_name} -> event for pending tool results (stream merge)
        pending_tool_events: %{},
        # Mission control assigns — agent cards + comms
        agent_cards: %{},
        concierge_card_names: [],
        system_card_names: [],
        worker_card_names: [],
        comms_event_count: 0,
        roster_refresh_timer: nil,
        mode: :mission_control,
        focused_agent: nil,
        inspector_mode: :auto_follow,
        collapsed_inspector: false,
        # Command palette state is now owned by CommandPaletteComponent
        # Ask-user pending questions
        pending_questions: [],
        # Collaboration health score (0-100) and periodic refresh timer
        collab_health: nil,
        collab_health_timer: nil,
        # Channel bindings for the active team
        channel_bindings: [],
        # Track subscribed PubSub teams to prevent duplicate subscriptions
        subscribed_teams: MapSet.new(),
        # Guard against duplicate global signal bus subscriptions
        global_signals_subscribed: false,
        # Debounce timer for metrics updates
        metrics_debounce_ref: nil,
        # Agent picker state is now owned by ComposerComponent
        # Cached roster data (recomputed on roster refresh, not per render)
        cached_agents: [],
        cached_tasks: [],
        cached_budget: %{spent: 0.0, limit: 5.0},
        budget_pct: 0,
        budget_bar_color_class: "bg-emerald-500",
        last_user_message: nil,
        failed_message_idx: nil,
        # Message queue UI state
        queue_drawer: nil,
        agent_queues: %{},
        scheduled_messages: [],
        # Kin management panel
        kin_panel_open: false,
        kin_agents: [],
        # File explorer drawer
        file_drawer_open: false,
        # Broadcast mode: true in team sessions, false in solo
        broadcast_mode: params["team_id"] != nil,
        # Leader approval gate pending (set when lead agent hits approval gate, nil otherwise)
        leader_approval_pending: nil,
        debug_signals: [],
        debug_panel_open: false
      )
      |> stream(:comms_events, [], limit: -500)

    case socket.assigns.live_action do
      :new ->
        project_path = params["project_path"] || File.cwd!()

        if connected?(socket) do
          # Check localStorage-stored session first (survives code reloads),
          # then fall back to most recently updated active session in DB.
          stored_sessions = get_connect_params(socket)["stored_sessions"] || %{}
          stored_id = stored_sessions[project_path]

          stored_session =
            if stored_id,
              do: Loomkin.Session.Persistence.get_session(stored_id),
              else: nil

          cond do
            stored_session && stored_session.status == :active &&
                stored_session.project_path == project_path ->
              {:ok, push_navigate(socket, to: ~p"/sessions/#{stored_session.id}")}

            latest = Loomkin.Session.Persistence.find_latest_active_session(project_path) ->
              {:ok, push_navigate(socket, to: ~p"/sessions/#{latest.id}")}

            true ->
              session_id = Ecto.UUID.generate()
              {:ok, start_and_subscribe(socket, session_id, project_path)}
          end
        else
          session_id = Ecto.UUID.generate()
          {:ok, start_and_subscribe(socket, session_id, project_path)}
        end

      :show ->
        session_id = params["session_id"]

        # Read the DB-stored project_path so resumed sessions use the correct
        # path instead of falling back to File.cwd!()
        db_project_path =
          case Loomkin.Session.Persistence.get_session(session_id) do
            %{project_path: path} when is_binary(path) -> path
            _ -> nil
          end

        {:ok, start_and_subscribe(socket, session_id, db_project_path)}
    end
  end

  def terminate(_reason, socket) do
    if broadcaster = socket.assigns[:broadcaster] do
      DynamicSupervisor.terminate_child(Loomkin.Teams.BroadcasterSupervisor, broadcaster)
    end

    if session_id = socket.assigns[:session_id] do
      Loomkin.Permissions.TrustPolicy.cleanup(session_id)
    end

    :ok
  end

  defp start_and_subscribe(socket, session_id, project_path) do
    # Initialize trust policy ETS table for this session (idempotent)
    Loomkin.Permissions.TrustPolicy.init(session_id)

    # Use full lead tool set — every session is a team-capable lead agent
    tools = Loomkin.Tools.Registry.for_lead()
    project_path = project_path || File.cwd!()

    {:ok, pid} =
      Manager.start_session(
        session_id: session_id,
        model: socket.assigns.model,
        fast_model: socket.assigns[:fast_model] || socket.assigns.model,
        project_path: project_path,
        tools: tools,
        auto_approve: false
      )

    # Read the effective model back from the session — for resumed sessions
    # this will be the DB-persisted model, not the mount default.
    effective_model =
      try do
        Session.get_model(pid)
      catch
        _, _ -> socket.assigns.model
      end

    effective_fast_model =
      try do
        Session.get_fast_model(pid)
      catch
        _, _ -> effective_model
      end

    # Proactively read team_id from session — covers the case where the team
    # was created during start_session but the :team_available PubSub event
    # hasn't been processed yet (common with longpoll reconnections).
    team_id_from_session =
      try do
        Session.get_team_id(pid)
      catch
        _, _ -> nil
      end

    socket =
      if team_id_from_session do
        bindings = load_channel_bindings(team_id_from_session)

        socket
        |> assign(
          team_id: team_id_from_session,
          active_team_id: team_id_from_session,
          mode: :mission_control,
          channel_bindings: bindings,
          broadcast_mode: true
        )
      else
        socket
      end

    socket =
      if connected?(socket) do
        Session.subscribe(session_id)

        # Start per-session TeamBroadcaster (replaces subscribe_global_signals)
        {:ok, broadcaster} =
          DynamicSupervisor.start_child(
            Loomkin.Teams.BroadcasterSupervisor,
            {TeamBroadcaster, team_ids: []}
          )

        TeamBroadcaster.subscribe(broadcaster, self())
        socket = assign(socket, broadcaster: broadcaster, global_signals_subscribed: true)

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

    # Ensure roster and cards are populated for resumed sessions with existing teams
    socket =
      if socket.assigns[:active_team_id] do
        require Logger

        Logger.info(
          "[Kin:UI] start_and_subscribe team=#{socket.assigns[:active_team_id]} — initial roster loaded"
        )

        socket |> refresh_roster() |> sync_cards_with_roster()
      else
        socket
      end

    # Load existing history — fall back to DB if session process is not running
    messages =
      case Session.get_history(session_id) do
        {:ok, msgs} ->
          msgs

        _ ->
          Loomkin.Session.Persistence.load_messages(session_id)
          |> Enum.map(&Map.take(&1, [:role, :content, :session_id, :inserted_at]))
      end

    session_metrics = Loomkin.Telemetry.Metrics.session_metrics(session_id)

    # Recover child teams if backing team exists — rebuild tree map from Manager
    team_id = socket.assigns[:team_id]

    team_tree =
      if team_id do
        child_ids = Teams.Manager.list_sub_teams(team_id)

        Enum.reduce(child_ids, %{}, fn child_id, acc ->
          case Teams.Manager.get_team_meta(child_id) do
            {:ok, meta} ->
              parent_id = meta[:parent_team_id] || team_id
              Map.update(acc, parent_id, [child_id], &[child_id | &1])

            _ ->
              acc
          end
        end)
      else
        %{}
      end

    active_team_id = socket.assigns[:active_team_id] || team_id
    channel_bindings = load_channel_bindings(active_team_id)

    # Load any pending scheduled messages from MessageScheduler (survives reconnects)
    scheduled_messages =
      if active_team_id do
        try do
          Loomkin.Teams.MessageScheduler.list(active_team_id)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    # Replay session message history as activity events so the feed
    # survives reconnections (longpoll or websocket drops).
    history_events = messages_to_activity_events(messages)

    known_agents =
      history_events
      |> Enum.map(& &1.agent)
      |> Enum.flat_map(fn agent ->
        case trackable_agent_name(agent) do
          nil -> []
          name -> [name]
        end
      end)
      |> Enum.uniq()

    # Send history events to the activity component (will arrive on first update)
    if history_events != [] do
      send_update(LoomkinWeb.TeamActivityComponent,
        id: "team-activity",
        reset_events: history_events
      )
    end

    socket =
      assign(socket,
        activity_known_agents: Enum.uniq(known_agents ++ socket.assigns.activity_known_agents),
        activity_event_count: length(history_events)
      )

    require Logger
    Logger.metadata(team: active_team_id, view: :workspace)

    assign(socket,
      session_id: session_id,
      project_path: project_path,
      explorer_path: project_path,
      editing_explorer_path: false,
      model: effective_model,
      fast_model: effective_fast_model,
      messages: messages,
      session_cost: session_metrics.cost_usd,
      session_tokens: session_metrics.prompt_tokens + session_metrics.completion_tokens,
      page_title: session_page_title(session_id),
      team_tree: team_tree,
      team_names: %{},
      active_team_id: active_team_id,
      scheduled_messages: scheduled_messages,
      switch_project_modal: nil,
      recent_projects: load_recent_projects(project_path),
      reply_target: nil,
      channel_bindings: channel_bindings,
      kin_agents: load_kin_agents(),
      trust_preset: Loomkin.Permissions.TrustPolicy.get_preset_name(session_id),
      trust_expanded: false
    )
  end

  # --- Events ---

  # Card events can arrive directly (from AgentCardComponent phx-click without
  # phx-target) or forwarded via MissionControlPanelComponent. Handle both paths.
  def handle_event("focus_card_agent", %{"agent" => agent_name}, socket) do
    send(self(), {:focus_agent, agent_name})
    {:noreply, socket}
  end

  def handle_event(
        "reply_to_card_agent",
        %{"agent" => agent_name, "team-id" => team_id},
        socket
      ) do
    send(self(), {:reply_to_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_event("pause_card_agent", %{"agent" => agent_name, "team-id" => team_id}, socket) do
    send(self(), {:pause_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_event("steer_card_agent", %{"agent" => agent_name, "team-id" => team_id}, socket) do
    send(self(), {:steer_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_event(
        "force_pause_card_agent",
        %{"agent" => agent_name, "team-id" => team_id},
        socket
      ) do
    case find_agent_pid(socket, agent_name, team_id) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.force_pause(pid)
        end)

      :error ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    trimmed = String.trim(text)

    case socket.assigns.reply_target do
      %{agent: agent_name, team_id: team_id, mode: :steer} ->
        # Steer a paused agent with user guidance
        case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
          {:ok, pid} ->
            Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
              Loomkin.Teams.Agent.steer(pid, trimmed)
            end)

            steer_event = %{
              id: Ecto.UUID.generate(),
              type: :message,
              agent: "You",
              content: "[Steering #{agent_name}]: #{trimmed}",
              timestamp: DateTime.utc_now(),
              expanded: false,
              metadata: %{from: "You", to: agent_name, action: :steer}
            }

            {:noreply,
             socket
             |> push_activity_event(steer_event)
             |> assign(
               input_text: "",
               reply_target: nil,
               last_user_message: %{text: trimmed, to: agent_name}
             )
             |> push_event("clear-input", %{})}

          :error ->
            {:noreply, assign(socket, reply_target: nil)}
        end

      %{agent: agent_name, team_id: team_id} ->
        # Direct reply to a specific agent — validate agent still exists
        case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
          {:ok, pid} ->
            Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
              Loomkin.Teams.Agent.send_message(pid, trimmed)
            end)

            reply_event = %{
              id: Ecto.UUID.generate(),
              type: :message,
              agent: "You",
              content: trimmed,
              timestamp: DateTime.utc_now(),
              expanded: false,
              metadata: %{from: "You", to: agent_name}
            }

            {:noreply,
             socket
             |> push_activity_event(reply_event)
             |> assign(
               input_text: "",
               reply_target: nil,
               last_user_message: %{text: trimmed, to: agent_name}
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
        if socket.assigns.broadcast_mode do
          team_id = socket.assigns.team_id
          agents = Loomkin.Teams.Manager.list_agents(team_id)
          session_id = socket.assigns.session_id

          # Always route through session for persistence + concierge handling
          task =
            Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
              Session.send_message(session_id, trimmed)
            end)

          # Additionally broadcast to non-bootstrap agents (for multi-agent awareness)
          Enum.each(agents, fn agent ->
            if agent.name != "concierge" do
              Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
                try do
                  Loomkin.Teams.Agent.inject_broadcast(
                    agent.pid,
                    "[Broadcast from Human]: #{trimmed}"
                  )
                catch
                  :exit, _ -> :ok
                end
              end)
            end
          end)

          user_msg = %{role: :user, content: trimmed}
          updated_messages = Enum.take(socket.assigns.messages ++ [user_msg], -@max_messages)

          broadcast_event = %{
            id: Ecto.UUID.generate(),
            type: :human_broadcast,
            agent: "You",
            content: trimmed,
            timestamp: DateTime.utc_now(),
            expanded: false,
            metadata: %{from: "You", to: "All Agents", agent_count: length(agents)}
          }

          {:noreply,
           socket
           |> push_activity_event(broadcast_event)
           |> assign(
             input_text: "",
             async_task: task,
             status: :thinking,
             messages: updated_messages,
             last_user_message: %{text: trimmed, to: "All Agents"}
           )
           |> push_event("clear-input", %{})}
        else
          # Normal flow: send through Architect pipeline
          session_id = socket.assigns.session_id

          task =
            Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
              Session.send_message(session_id, trimmed)
            end)

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
                metadata: %{from: "You", to: "Kin"}
              }

              socket
              |> push_activity_event(user_event)
            else
              socket
            end

          # Append preserves chronological order required by ChatComponent stream diffing
          updated_messages = Enum.take(socket.assigns.messages ++ [user_msg], -@max_messages)

          # Auto-title page from first user message
          socket =
            if socket.assigns.messages == [] do
              title =
                trimmed
                |> String.split(~r/[\n\r]/, parts: 2)
                |> List.first("")
                |> String.trim()
                |> String.slice(0, 60)

              title = if title == "", do: "New session", else: title
              assign(socket, page_title: title)
            else
              socket
            end

          {:noreply,
           socket
           |> assign(
             input_text: "",
             async_task: task,
             status: :thinking,
             messages: updated_messages,
             last_user_message: %{text: trimmed, to: "Kin"}
           )
           |> push_event("clear-input", %{})}
        end
    end
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    Session.cancel(socket.assigns.session_id)

    {:noreply,
     assign(socket, status: :idle, streaming: false, streaming_content: "", streaming_agent: nil)}
  end

  def handle_event("reply_to_agent", %{"agent" => agent_name}, socket) do
    # Find the agent's team_id from the cached roster data
    agents = socket.assigns.cached_agents

    team_id =
      Enum.find_value(agents, socket.assigns.active_team_id, fn a ->
        if a.name == agent_name, do: a.team_id
      end)

    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, reply_target: nil)}
  end

  # toggle_agent_picker, select_reply_target, close_agent_picker moved to ComposerComponent

  def handle_event("open_kin_panel", _params, socket) do
    {:noreply, assign(socket, kin_panel_open: true)}
  end

  def handle_event("spawn_dormant_kin", %{"id" => id}, socket) do
    case Loomkin.Kin.get_kin(id) do
      nil ->
        {:noreply, socket}

      kin ->
        send(self(), {:spawn_kin_agent, kin})
        {:noreply, socket}
    end
  end

  @valid_tabs ~w(files diff graph)
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @valid_tabs do
    tab_atom = String.to_existing_atom(tab)

    socket =
      if tab_atom == :team and socket.assigns.buffered_activity_events != [] do
        # Flush buffered events to the component now that it's visible
        events = Enum.reverse(socket.assigns.buffered_activity_events)

        send_update(LoomkinWeb.TeamActivityComponent,
          id: "team-activity",
          reset_events: events
        )

        assign(socket, buffered_activity_events: [])
      else
        socket
      end

    {:noreply, assign(socket, active_tab: tab_atom)}
  end

  def handle_event("change_model", %{"model" => model}, socket) do
    Session.update_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/?new=true")}
  end

  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{id}")}
  end

  def handle_event("deselect_file", _params, socket) do
    {:noreply, assign(socket, selected_file: nil, file_content: nil)}
  end

  def handle_event("toggle_trust_panel", _params, socket) do
    {:noreply, update(socket, :trust_expanded, &(!&1))}
  end

  def handle_event("toggle_file_drawer", _params, socket) do
    {:noreply, assign(socket, file_drawer_open: !socket.assigns.file_drawer_open)}
  end

  def handle_event("toggle_debug_panel", _params, socket) do
    {:noreply, update(socket, :debug_panel_open, &(!&1))}
  end

  def handle_event("toggle_debug", _params, socket) do
    {:noreply, update(socket, :debug_panel_open, &(!&1))}
  end

  @valid_trust_presets ~w(strict balanced autonomous full_trust)
  def handle_event("set_trust_preset", %{"preset" => preset_str}, socket)
      when preset_str in @valid_trust_presets do
    preset = String.to_existing_atom(preset_str)

    case Loomkin.Permissions.TrustPolicy.apply_preset(socket.assigns.session_id, preset) do
      :ok -> {:noreply, assign(socket, trust_preset: preset)}
      {:error, :unknown_preset} -> {:noreply, socket}
    end
  end

  def handle_event("set_trust_preset", _params, socket) do
    {:noreply, socket}
  end

  @valid_sub_tabs ~w(activity cost graph)
  def handle_event("switch_sub_tab", %{"tab" => tab}, socket) when tab in @valid_sub_tabs do
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

  def handle_event("restore_ui_state", params, socket) do
    socket =
      socket
      |> restore_assign(:mode, params["mode"], ~w(solo mission_control))
      |> restore_assign(:active_tab, params["active_tab"], @valid_tabs)
      |> restore_assign(:inspector_mode, params["inspector_mode"], ~w(auto_follow pinned))
      |> restore_assign_bool(:collapsed_inspector, params["collapsed_inspector"])
      |> restore_assign_string(:focused_agent, params["focused_agent"])

    {:noreply, socket}
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
    {:noreply,
     assign(socket,
       focused_agent: nil,
       inspector_mode: :auto_follow,
       reply_target: nil
     )}
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_input"}, socket) do
    {:noreply, push_event(socket, "focus-input", %{})}
  end

  def handle_event("keyboard_shortcut", %{"key" => "command_palette"}, socket) do
    send_update(LoomkinWeb.CommandPaletteComponent, id: "command-palette", toggle: true)
    {:noreply, socket}
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_panel_4"}, socket) do
    {:noreply, assign(socket, file_drawer_open: !socket.assigns.file_drawer_open)}
  end

  def handle_event("keyboard_shortcut", %{"key" => "focus_panel_5"}, socket) do
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

  # palette_search, palette_select, close_command_palette moved to CommandPaletteComponent

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
        socket = handle_collective_decision(socket, question)
        {:noreply, assign(socket, pending_questions: remaining)}
      else
        # Validate that the submitted answer is one of the original options to prevent
        # arbitrary answers submitted via DOM manipulation
        valid_options = question.options || []

        if answer in valid_options do
          # Send answer directly back to the waiting agent
          send_ask_user_answer(question_id, answer)

          # Update the agent card's pending_questions to stay in sync
          agent_remaining = Enum.filter(remaining, &(&1.agent_name == question.agent_name))

          socket =
            socket
            |> assign(pending_questions: remaining)
            |> update_agent_card(question.agent_name, %{pending_questions: agent_remaining})

          {:noreply, socket}
        else
          {:noreply, socket}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("let_team_decide", %{"agent" => agent_name}, socket) do
    agent_questions =
      Enum.filter(socket.assigns.pending_questions, &(&1.agent_name == agent_name))

    # Call handle_collective_decision for each question, threading the socket
    socket =
      Enum.reduce(agent_questions, socket, fn q, acc_socket ->
        handle_collective_decision(acc_socket, q)
      end)

    remaining = Enum.reject(socket.assigns.pending_questions, &(&1.agent_name == agent_name))

    socket =
      socket
      |> assign(pending_questions: remaining)
      |> update_agent_card(agent_name, %{pending_questions: []})

    {:noreply, socket}
  end

  # --- Approval Gate ---

  def handle_event(
        "approve_card_agent",
        %{"gate_id" => gate_id, "agent" => agent_name} = params,
        socket
      ) do
    context =
      case params["context"] do
        nil -> nil
        "" -> nil
        v -> v
      end

    send_approval_response(gate_id, %{outcome: :approved, context: context})
    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})

    socket =
      if socket.assigns.leader_approval_pending[:gate_id] == gate_id do
        assign(socket, leader_approval_pending: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event(
        "deny_card_agent",
        %{"gate_id" => gate_id, "agent" => agent_name} = params,
        socket
      ) do
    reason =
      case params["reason"] do
        nil -> nil
        "" -> nil
        v -> v
      end

    send_approval_response(gate_id, %{outcome: :denied, reason: reason, context: nil})
    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})

    socket =
      if socket.assigns.leader_approval_pending[:gate_id] == gate_id do
        assign(socket, leader_approval_pending: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  # --- Spawn Gate ---

  def handle_event(
        "approve_spawn",
        %{"gate_id" => gate_id, "agent" => agent_name} = params,
        socket
      ) do
    context = params["context"]
    send_spawn_gate_response(gate_id, %{outcome: :approved, context: context})
    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})
    {:noreply, socket}
  end

  def handle_event(
        "deny_spawn",
        %{"gate_id" => gate_id, "agent" => agent_name} = params,
        socket
      ) do
    reason = params["reason"] || ""
    send_spawn_gate_response(gate_id, %{outcome: :denied, reason: reason})
    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})
    {:noreply, socket}
  end

  def handle_event(
        "toggle_auto_approve_spawns",
        %{"agent" => agent_name, "enabled" => enabled_str},
        socket
      ) do
    enabled = enabled_str == "true"

    case find_agent_pid(socket, agent_name, nil) do
      {:ok, pid} -> GenServer.call(pid, {:set_auto_approve_spawns, enabled})
      :error -> :ok
    end

    # Update the agent card so the checkbox reflects the new state
    socket =
      case get_in(socket.assigns, [:agent_cards, agent_name, :pending_approval]) do
        %{} = pa ->
          update_agent_card(socket, agent_name, %{
            pending_approval: Map.put(pa, :auto_approve_spawns, enabled)
          })

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Agent card actions now forwarded via {:mission_control_event, ...}
  # Queue drawer toggle now forwarded via {:composer_event, ...}

  def handle_event("close_queue_drawer", _params, socket) do
    {:noreply, assign(socket, queue_drawer: nil)}
  end

  # toggle_scheduler, close_scheduler, set_schedule_delay moved to ComposerComponent

  def handle_event(
        "schedule_message",
        %{"content" => content, "delay_minutes" => delay} = params,
        socket
      ) do
    target_agent = params["target_agent"]
    delay_minutes = String.to_integer(delay)
    team_id = socket.assigns.active_team_id
    deliver_at = DateTime.add(DateTime.utc_now(), delay_minutes * 60, :second)

    case Loomkin.Teams.MessageScheduler.schedule(team_id, content, target_agent, deliver_at) do
      {:ok, _msg} ->
        {:noreply,
         socket
         |> assign(input_text: "")
         |> put_flash(:info, "Message scheduled for #{delay_minutes}m from now")
         |> push_event("clear-input", %{})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to schedule: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel_scheduled", %{"id" => id}, socket) do
    team_id = socket.assigns.active_team_id
    Loomkin.Teams.MessageScheduler.cancel(team_id, id)
    {:noreply, socket}
  end

  # --- Enqueue & Guidance ---

  def handle_event("enqueue_message", _params, socket) do
    text = String.trim(socket.assigns.input_text || "")

    if text == "" do
      {:noreply, socket}
    else
      case socket.assigns.reply_target do
        %{agent: agent_name, team_id: team_id} ->
          case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
            {:ok, pid} ->
              Loomkin.Teams.Agent.enqueue(pid, text, source: :user, priority: :normal)

            :error ->
              :ok
          end

          {:noreply,
           socket
           |> assign(input_text: "")
           |> put_flash(:info, "Message queued for #{agent_name}")
           |> push_event("clear-input", %{})}

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("inject_guidance", _params, socket) do
    text = String.trim(socket.assigns.input_text || "")

    if text == "" do
      {:noreply, socket}
    else
      case socket.assigns.reply_target do
        %{agent: agent_name, team_id: team_id} ->
          case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
            {:ok, pid} ->
              Loomkin.Teams.Agent.inject_guidance(pid, text)

            :error ->
              :ok
          end

          guidance_event = %{
            id: Ecto.UUID.generate(),
            type: :message,
            agent: "You",
            content: "[Guidance to #{agent_name}]: #{text}",
            timestamp: DateTime.utc_now(),
            expanded: false,
            metadata: %{from: "You", to: agent_name, action: :guidance}
          }

          {:noreply,
           socket
           |> push_activity_event(guidance_event)
           |> assign(
             input_text: "",
             last_user_message: %{text: text, to: agent_name}
           )
           |> push_event("clear-input", %{})}

        _ ->
          {:noreply, socket}
      end
    end
  end

  # --- Component Info Messages ---

  # Forwarded from TeamTreeComponent — same logic as "switch_team" event handler
  def handle_info({:switch_team, team_id}, socket) do
    bindings = load_channel_bindings(team_id)

    {:noreply,
     assign(socket, active_team_id: team_id, channel_bindings: bindings, reply_target: nil)}
  end

  def handle_info({:reply_to_agent, agent_name}, socket) do
    # Forwarded from roster component — same logic as the event handler
    agents = socket.assigns.cached_agents

    team_id =
      Enum.find_value(agents, socket.assigns.active_team_id, fn a ->
        if a.name == agent_name, do: a.team_id
      end)

    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
  end

  # --- Signal Bus dispatch ---
  # Converts Jido.Signal structs from the Bus into the tuple format
  # that existing handle_info clauses expect. As more modules migrate to
  # signals, eventually the tuple clauses will be removed.

  # Batched signals from TeamBroadcaster — critical signals (instant delivery)
  def handle_info({:team_broadcast, %{critical: signals}}, socket) do
    socket = Enum.reduce(signals, socket, &dispatch_signal/2)
    {:noreply, socket}
  end

  # Batched signals from TeamBroadcaster — regular batched delivery
  def handle_info({:team_broadcast, batch}, socket) when is_map(batch) do
    signals = Enum.flat_map(batch, fn {_category, sigs} -> sigs end)
    socket = Enum.reduce(signals, socket, &dispatch_signal/2)
    {:noreply, socket}
  end

  # TeamBroadcaster pre-filters signals by team_id, so no additional filtering needed.
  # child_team_created is routed by parent_team_id via extract_team_id/1 in TeamBroadcaster.
  def handle_info({:signal, %Jido.Signal{} = sig}, socket) do
    {:noreply, dispatch_signal(sig, socket)}
  end

  def handle_info(%Jido.Signal{type: "agent.status"} = sig, socket) do
    %{agent_name: agent_name, status: status} = sig.data

    metadata = %{
      previous_status: sig.data[:previous_status],
      pause_queued: sig.data[:pause_queued] || false
    }

    handle_info({:agent_status, agent_name, status, metadata}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.role.changed"} = sig, socket) do
    %{agent_name: name, old_role: old_role, new_role: new_role} = sig.data
    handle_info({:role_changed, name, old_role, new_role}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.escalation"} = sig, socket) do
    %{agent_name: name, from_model: from, to_model: to} = sig.data
    handle_info({:agent_escalation, name, from, to}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.stream.start"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:agent_stream_start, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.stream.delta"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:agent_stream_delta, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.stream.end"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:agent_stream_end, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.tool.executing"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:tool_executing, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.tool.complete"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:tool_complete, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.usage"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:usage, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "agent.error"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:agent_error, name, payload}, socket)
  end

  # --- Healing signals ---

  def handle_info(%Jido.Signal{type: "healing.session.started"} = sig, socket) do
    %{agent_name: agent_name, classification: classification} = sig.data

    category =
      case classification do
        %{category: cat} -> to_string(cat)
        _ -> "unknown"
      end

    socket =
      socket
      |> update_agent_card(agent_name, %{
        status: :suspended_healing,
        healing_phase: :diagnosing,
        healing_error_category: category
      })

    event = %{
      id: Ecto.UUID.generate(),
      type: :healing_started,
      agent: agent_name,
      content: "#{agent_name} suspended for healing: #{category}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{session_id: sig.data[:session_id], team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "healing.diagnosis.complete"} = sig, socket) do
    %{agent_name: agent_name, root_cause: root_cause, confidence: confidence} = sig.data

    socket = update_agent_card(socket, agent_name, %{healing_phase: :fixing})

    confidence_pct = round(confidence * 100)

    event = %{
      id: Ecto.UUID.generate(),
      type: :healing_diagnosis,
      agent: agent_name,
      content: "Diagnosis: #{root_cause} (confidence: #{confidence_pct}%)",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{session_id: sig.data[:session_id], team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "healing.fix.applied"} = sig, socket) do
    %{agent_name: agent_name, files_changed: files_changed} = sig.data

    socket = update_agent_card(socket, agent_name, %{healing_phase: :confirming})

    file_count = length(files_changed)

    files_display =
      case files_changed do
        [] -> "none"
        [f] -> f
        [f1, f2] -> "#{f1}, #{f2}"
        [f | _] -> "#{f} and #{file_count - 1} more"
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :healing_fix_applied,
      agent: agent_name,
      content: "Fix applied to #{file_count} file(s): #{files_display}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{session_id: sig.data[:session_id], team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "healing.session.complete"} = sig, socket) do
    %{agent_name: agent_name, outcome: outcome, duration_ms: duration_ms} = sig.data

    card_updates =
      case outcome do
        :healed ->
          %{healing_phase: nil, healing_error_category: nil}

        _ ->
          %{healing_phase: nil, healing_error_category: nil, status: :error}
      end

    socket = update_agent_card(socket, agent_name, card_updates)

    {event_type, content} =
      case outcome do
        :healed ->
          {:healing_complete,
           "Healing complete: #{agent_name} resumed (#{format_duration(duration_ms)})"}

        :escalated ->
          {:healing_failed,
           "Healing failed: #{agent_name} escalated (#{format_duration(duration_ms)})"}

        :timed_out ->
          {:healing_failed,
           "Healing timed out: #{agent_name} escalated (#{format_duration(duration_ms)})"}

        :cancelled ->
          {:healing_failed, "Healing cancelled: #{agent_name} (#{format_duration(duration_ms)})"}
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: event_type,
      agent: agent_name,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{
        session_id: sig.data[:session_id],
        team_id: sig.data[:team_id],
        outcome: outcome
      }
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "context.offloaded"} = sig, socket) do
    %{agent_name: name, payload: payload} = sig.data
    handle_info({:context_offloaded, name, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "team.permission.request"} = sig, socket) do
    %{team_id: tid, tool_name: tn, tool_path: tp, source: source} = sig.data

    agent_name =
      case source do
        {:agent, _team_id, name} -> to_string(name)
        _ -> "session"
      end

    {:noreply, enqueue_or_auto_respond(socket, agent_name, :any, tn, tp, source, tid)}
  end

  # --- Approval Gate signals ---

  def handle_info(%Jido.Signal{type: "agent.approval.requested"} = sig, socket) do
    %{gate_id: gate_id, agent_name: agent_name, question: question, timeout_ms: timeout_ms} =
      sig.data

    started_at = System.system_time(:millisecond)

    pending_approval = %{
      gate_id: gate_id,
      question: question,
      timeout_ms: timeout_ms,
      started_at: started_at
    }

    socket = update_agent_card(socket, agent_name, %{pending_approval: pending_approval})

    role = get_in(socket.assigns, [:agent_cards, agent_name, :role])

    socket =
      if role == :lead do
        assign(socket,
          leader_approval_pending: %{
            gate_id: gate_id,
            question: question,
            timeout_ms: timeout_ms,
            started_at: started_at
          }
        )
      else
        socket
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :approval_gate_requested,
      agent: agent_name,
      content: "#{agent_name} is requesting approval: #{question}",
      timestamp: DateTime.utc_now(),
      expanded: true,
      metadata: %{gate_id: gate_id}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.approval.resolved"} = sig, socket) do
    %{gate_id: gate_id, agent_name: agent_name, outcome: outcome} = sig.data

    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})

    socket =
      if socket.assigns.leader_approval_pending[:gate_id] == gate_id do
        assign(socket, leader_approval_pending: nil)
      else
        socket
      end

    outcome_label =
      case outcome do
        :timeout -> "timed out"
        :approved -> "approved"
        :denied -> "denied"
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :approval_gate_resolved,
      agent: agent_name,
      content: "Approval gate #{outcome_label} by human",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{gate_id: gate_id, outcome: outcome}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  # --- Spawn Gate signals ---

  def handle_info(%Jido.Signal{type: "agent.spawn.gate.requested"} = sig, socket) do
    %{
      gate_id: gate_id,
      agent_name: agent_name,
      team_name: team_name,
      roles: roles,
      estimated_cost: estimated_cost
    } = sig.data

    timeout_ms = sig.data[:timeout_ms] || 300_000
    limit_warning = sig.data[:limit_warning]
    purpose = sig.data[:purpose]
    auto_approve_spawns = sig.data[:auto_approve_spawns] || false

    pending_approval = %{
      type: :spawn_gate,
      gate_id: gate_id,
      team_name: team_name,
      purpose: purpose,
      roles: roles,
      estimated_cost: estimated_cost,
      limit_warning: limit_warning,
      timeout_ms: timeout_ms,
      started_at: System.system_time(:millisecond),
      auto_approve_spawns: auto_approve_spawns
    }

    socket = update_agent_card(socket, agent_name, %{pending_approval: pending_approval})

    role_count = if is_map(roles), do: map_size(roles), else: length(roles)
    cost = estimated_cost || 0.0

    event = %{
      id: Ecto.UUID.generate(),
      type: :spawn_gate_opened,
      agent: agent_name,
      content:
        "#{agent_name} requesting approval to spawn #{team_name} (#{role_count} roles, est. $#{Float.round(cost, 4)})",
      timestamp: DateTime.utc_now(),
      expanded: true,
      metadata: %{gate_id: gate_id, team_name: team_name, estimated_cost: cost}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.spawn.gate.resolved"} = sig, socket) do
    %{agent_name: agent_name} = sig.data
    outcome = sig.data[:outcome] || :approved

    socket = update_agent_card(socket, agent_name, %{pending_approval: nil})

    outcome_label =
      case outcome do
        :approved -> "approved"
        :denied -> "denied"
        :timeout -> "timed out"
        _ -> "resolved"
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :spawn_gate_resolved,
      agent: agent_name,
      content: "Spawn gate #{outcome_label} for #{agent_name}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{outcome: outcome}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "team.dissolved"} = sig, socket) do
    %{team_id: tid} = sig.data
    handle_info({:team_dissolved, tid}, socket)
  end

  def handle_info(%Jido.Signal{type: "team.child.created"} = sig, socket) do
    %{team_id: tid, parent_team_id: parent_id, team_name: team_name} = sig.data
    handle_info({:child_team_created, tid, parent_id, team_name}, socket)
  end

  def handle_info(%Jido.Signal{type: "team.ask_user.question"} = sig, socket) do
    handle_info({:ask_user_question, sig.data}, socket)
  end

  def handle_info(%Jido.Signal{type: "team.ask_user.answered"} = sig, socket) do
    %{question_id: qid, answer: answer} = sig.data
    handle_info({:ask_user_answered, qid, answer}, socket)
  end

  def handle_info(%Jido.Signal{type: "context.update"} = sig, socket) do
    %{from: from} = sig.data
    payload = sig.data
    handle_info({:context_update, from, payload}, socket)
  end

  def handle_info(%Jido.Signal{type: "context.keeper.created"} = sig, socket) do
    handle_info({:keeper_created, sig.data}, socket)
  end

  def handle_info(%Jido.Signal{type: "decision.node.added"} = sig, socket) do
    handle_info({:node_added, sig.data}, socket)
  end

  def handle_info(%Jido.Signal{type: "decision.pivot.created"} = sig, socket) do
    handle_info({:pivot_created, sig.data}, socket)
  end

  def handle_info(%Jido.Signal{type: "decision.logged"} = sig, socket) do
    %{node_id: nid, agent_name: name} = sig.data
    handle_info({:decision_logged, nid, name}, socket)
  end

  def handle_info(%Jido.Signal{type: "channel.message"} = sig, socket) do
    handle_info({:channel_message, sig.data}, socket)
  end

  def handle_info(%Jido.Signal{type: "collaboration.vote.response"} = sig, socket) do
    response = sig.data[:response] || %{}
    agent = response[:from] || "unknown"
    choice = response[:choice] || "abstain"
    confidence = response[:confidence]

    content =
      if confidence,
        do: "voted '#{choice}' (confidence: #{confidence})",
        else: "voted '#{choice}'"

    event = %{
      id: Ecto.UUID.generate(),
      type: :vote_response,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{
        team_id: sig.data[:team_id],
        vote_id: sig.data[:vote_id],
        choice: choice,
        confidence: confidence
      }
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.debate.response"} = sig, socket) do
    response = sig.data[:response] || %{}
    agent = response[:from] || "unknown"
    phase = sig.data[:phase] || :unknown

    content =
      case phase do
        :vote ->
          choice = response[:choice] || "no choice"
          "debate vote: '#{choice}'"

        _ ->
          response[:content] || "no response"
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :debate_response,
      agent: agent,
      content: "[#{phase}] #{content}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{
        team_id: sig.data[:team_id],
        debate_id: sig.data[:debate_id],
        phase: phase
      }
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "system.auth." <> _} = sig, socket) do
    tuple =
      case sig.type do
        "system.auth.connected" -> {:auth_connected, sig.data.provider}
        "system.auth.disconnected" -> {:auth_disconnected, sig.data.provider}
        "system.auth.refreshed" -> {:auth_refreshed, sig.data.provider}
        "system.auth.refresh_failed" -> {:auth_refresh_failed, sig.data.provider, nil}
        _ -> nil
      end

    if tuple, do: handle_info(tuple, socket), else: {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "system.metrics.updated"}, socket) do
    # Debounce metrics updates to at most once per second
    if socket.assigns[:metrics_debounce_ref] do
      {:noreply, socket}
    else
      ref = Process.send_after(self(), :refresh_metrics, 1_000)
      {:noreply, assign(socket, metrics_debounce_ref: ref)}
    end
  end

  def handle_info(%Jido.Signal{type: "session.message.new"} = sig, socket) do
    %{session_id: sid} = sig.data

    if sid == socket.assigns.session_id do
      socket = append_debug_signal(socket, sig)
      msg = Map.get(sig.data, :message, sig.data)
      handle_info({:new_message, sid, msg}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Jido.Signal{type: "session.status.changed"} = sig, socket) do
    %{session_id: sid, status: status} = sig.data

    if sid == socket.assigns.session_id do
      socket = append_debug_signal(socket, sig)

      # Forward raw event to existing handlers (e.g., stream_start/delta/end)
      socket = forward_raw_event(socket, sig.data[:raw_event])

      # Don't overwrite valid status with :unknown
      if status == :unknown do
        require Logger
        Logger.warning("[Kin:UI] received :unknown status — architect catch-all fired")
        {:noreply, socket}
      else
        {:noreply, assign(socket, status: status)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Jido.Signal{type: "agent.queue.updated"} = sig, socket) do
    %{agent_name: agent_name, queue: queue} = sig.data
    handle_info({:queue_updated, agent_name, queue}, socket)
  end

  # Rebalancer signals — stuck agent nudges and escalations
  def handle_info(%Jido.Signal{type: "team.rebalance.needed"} = sig, socket) do
    agent_name = to_string(sig.data[:agent_name] || "unknown")
    event_type = sig.data[:event] || :escalation
    idle_min = sig.data[:idle_min] || 0

    {comms_type, content} =
      case event_type do
        :nudge ->
          nudge_count = sig.data[:nudge_count] || 1
          max_nudges = sig.data[:max_nudges] || 2

          {:rebalance_nudge,
           "#{agent_name} stuck for #{idle_min}m — nudge #{nudge_count}/#{max_nudges}"}

        _escalation ->
          task_info = sig.data[:task_info]
          task_suffix = if task_info && task_info != "", do: " (task: #{task_info})", else: ""

          {:rebalance_escalation,
           "#{agent_name} stuck for #{idle_min}m — escalating#{task_suffix}"}
      end

    comms_event = %{
      id: Ecto.UUID.generate(),
      type: comms_type,
      agent: agent_name,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{
        team_id: sig.data[:team_id],
        idle_min: idle_min,
        event: event_type,
        nudge_count: sig.data[:nudge_count],
        max_nudges: sig.data[:max_nudges],
        task_info: sig.data[:task_info]
      }
    }

    # Set stuck_warning on the agent card
    card_updates =
      case event_type do
        :nudge ->
          %{
            stuck_warning: true,
            stuck_idle_min: idle_min,
            stuck_nudge_count: sig.data[:nudge_count] || 1,
            stuck_max_nudges: sig.data[:max_nudges] || 2
          }

        _escalation ->
          %{
            stuck_warning: true,
            stuck_idle_min: idle_min,
            stuck_escalated: true
          }
      end

    socket =
      socket
      |> update_agent_card(agent_name, card_updates)
      |> stream_insert(:comms_events, comms_event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  # Peer-to-peer agent messages — critical-priority delivery via TeamBroadcaster
  def handle_info(%Jido.Signal{type: "collaboration.peer.message"} = sig, socket) do
    agent = sig.data[:from] || "unknown"

    content =
      case sig.data[:message] do
        {:peer_message, _sender, text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    event = %{
      id: Ecto.UUID.generate(),
      type: :peer_message,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  # Agent crash/recovery signals — update card status and insert comms events
  def handle_info(%Jido.Signal{type: "agent.crashed"} = sig, socket) do
    agent_name = sig.data[:agent_name] || "unknown"
    crash_count = sig.data[:crash_count] || 1
    reason = sig.data[:reason] || "unknown"

    event = %{
      id: Ecto.UUID.generate(),
      type: :agent_crashed,
      agent: agent_name,
      content: "#{agent_name} crashed (reason: #{inspect(reason)})",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> update_card_status(agent_name, :crashed)
      |> update_agent_card(agent_name, %{crash_count: crash_count})
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.recovered"} = sig, socket) do
    agent_name = sig.data[:agent_name] || "unknown"
    crash_count = sig.data[:crash_count] || 0

    event = %{
      id: Ecto.UUID.generate(),
      type: :agent_recovered,
      agent: agent_name,
      content: "#{agent_name} recovered (crash count: #{crash_count})",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{team_id: sig.data[:team_id]}
    }

    Process.send_after(self(), {:clear_recovering, agent_name}, 2_000)

    socket =
      socket
      |> update_card_status(agent_name, :recovering)
      |> update_agent_card(agent_name, %{crash_count: crash_count})
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.permanently_failed"} = sig, socket) do
    agent_name = sig.data[:agent_name] || "unknown"
    crash_count = sig.data[:crash_count] || 0

    event = %{
      id: Ecto.UUID.generate(),
      type: :agent_permanently_failed,
      agent: agent_name,
      content: "#{agent_name} permanently failed after #{crash_count} crashes",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{team_id: sig.data[:team_id]}
    }

    socket =
      socket
      |> update_card_status(agent_name, :permanently_failed)
      |> update_agent_card(agent_name, %{crash_count: crash_count})
      |> stream_insert(:comms_events, event)
      |> update(:comms_event_count, &(&1 + 1))

    {:noreply, socket}
  end

  # Catch-all for unhandled signal types — ignore
  def handle_info(%Jido.Signal{type: _type}, socket) do
    {:noreply, socket}
  end

  # --- PubSub Info ---

  def handle_info({:new_message, _session_id, %{role: :user}}, socket) do
    # User messages are added optimistically in handle_event — skip PubSub duplicate
    {:noreply, socket}
  end

  def handle_info({:new_message, _session_id, msg}, socket) do
    # Append preserves chronological order required by ChatComponent stream diffing
    socket = assign(socket, messages: Enum.take(socket.assigns.messages ++ [msg], -@max_messages))

    # Also add assistant messages to activity feed for mission control mode
    socket =
      if msg.role == :assistant do
        agent_name = Map.get(msg, :from, "Architect")

        event = %{
          id: Ecto.UUID.generate(),
          type: :message,
          agent: agent_name,
          content: msg.content,
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: %{from: agent_name, role: :assistant}
        }

        socket
        |> append_activity_event(event)
        |> update_agent_card(agent_name, %{
          content_type: :message,
          latest_content: msg.content,
          last_response: msg.content
        })
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

  def handle_info({:session_status, _session_id, :unknown}, socket) do
    # Don't overwrite valid status with :unknown
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
      |> forward_to_cards_and_comms(event)
      |> maybe_auto_follow(source, %{tool_name: name, path: target})
      # current_tool includes target path for component display (e.g. "read: /path/to/file"),
      # current_tool_name is the raw tool name used by status_label in the status pill.
      |> assign(current_tool: display, current_tool_name: name)

    {:noreply, socket}
  end

  def handle_info({:tool_executing, source, %{tool_name: name}} = event, socket) do
    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
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
      |> forward_to_cards_and_comms(event)
      |> assign(current_tool: nil, current_tool_name: nil)

    {:noreply, socket}
  end

  # Session tool_complete (4-element tuple with result)
  def handle_info({:tool_complete, _session_id, tool_name, result}, socket) do
    socket = assign(socket, current_tool: nil, current_tool_name: nil)

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
          # Append preserves chronological order required by DiffComponent rendering
          assign(socket, diffs: Enum.take(socket.assigns.diffs ++ [diff], -@max_diffs))

        true ->
          socket
      end

    {:noreply, socket}
  end

  # 5-tuple with source tag (from architect :session or {:agent, team_id, name})
  def handle_info({:permission_request, team_id, tool_name, tool_path, source}, socket) do
    agent_name =
      case source do
        {:agent, _team_id, name} -> to_string(name)
        _ -> "session"
      end

    {:noreply,
     enqueue_or_auto_respond(socket, agent_name, :any, tool_name, tool_path, source, team_id)}
  end

  # 4-tuple backwards compat (default to :session source)
  def handle_info({:permission_request, _session_id, tool_name, tool_path}, socket) do
    {:noreply,
     enqueue_or_auto_respond(
       socket,
       "session",
       :any,
       tool_name,
       tool_path,
       :session,
       socket.assigns[:team_id] || socket.assigns.session_id
     )}
  end

  def handle_info({:team_available, _session_id, team_id}, socket) do
    require Logger
    Logger.info("[Kin:UI] :team_available team=#{team_id}")
    bindings = load_channel_bindings(team_id)

    scheduled =
      try do
        Loomkin.Teams.MessageScheduler.list(team_id)
      catch
        :exit, _ -> []
      end

    socket =
      socket
      |> subscribe_to_team(team_id)
      |> assign(
        team_id: team_id,
        active_team_id: team_id,
        mode: :mission_control,
        channel_bindings: bindings,
        scheduled_messages: scheduled
      )
      |> refresh_roster()
      |> sync_cards_with_roster()
      |> schedule_collab_health_refresh()

    Logger.info(
      "[Kin:UI] :team_available complete — cards=#{inspect(Map.keys(socket.assigns.agent_cards))}"
    )

    {:noreply, socket}
  end

  def handle_info({:child_team_available, _session_id, child_team_id}, socket) do
    socket = subscribe_to_team(socket, child_team_id)

    # Use team_id as fallback parent for session reconnect path (no signal data available)
    parent_id = socket.assigns.team_id || child_team_id

    updated_tree =
      if child_team_id in Map.get(socket.assigns.team_tree, parent_id, []) do
        socket.assigns.team_tree
      else
        Map.update(socket.assigns.team_tree, parent_id, [child_team_id], &[child_team_id | &1])
      end

    socket =
      socket
      |> assign(team_tree: updated_tree, mode: :mission_control)
      |> schedule_roster_refresh()

    {:noreply, socket}
  end

  def handle_info(:debounced_roster_refresh, socket) do
    require Logger
    Logger.debug("[Kin:UI] debounced roster refresh fired")

    socket =
      socket
      |> refresh_roster()
      |> sync_cards_with_roster()
      |> assign(roster_refresh_timer: nil)

    {:noreply, socket}
  end

  # --- Errors ---

  def handle_info({:session_cancelled, _session_id}, socket) do
    {:noreply,
     socket
     |> assign(streaming: false, streaming_content: "", streaming_agent: nil, status: :idle)
     |> put_flash(:info, "Request cancelled")}
  end

  def handle_info({:llm_error, _session_id, message}, socket) do
    {:noreply,
     socket
     |> assign(streaming: false, streaming_content: "", streaming_agent: nil, status: :idle)
     |> put_flash(:error, message)}
  end

  # --- Streaming ---

  def handle_info({:stream_start, _session_id}, socket) do
    {:noreply,
     assign(socket, streaming: true, streaming_content: "", streaming_agent: "Architect")}
  end

  def handle_info({:stream_delta, _session_id, %{text: chunk}}, socket) do
    {:noreply, assign(socket, streaming_content: socket.assigns.streaming_content <> chunk)}
  end

  def handle_info({:stream_end, _session_id}, socket) do
    {:noreply, assign(socket, streaming: false, streaming_content: "", streaming_agent: nil)}
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

    task =
      Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
        Session.send_message(session_id, prompt)
      end)

    user_msg = %{role: :user, content: prompt}

    {:noreply,
     socket
     |> assign(
       input_text: "",
       async_task: task,
       status: :thinking,
       # Append preserves chronological order required by ChatComponent stream diffing
       messages: Enum.take(socket.assigns.messages ++ [user_msg], -@max_messages)
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

  def handle_info(:close_kin_panel, socket) do
    {:noreply, assign(socket, kin_panel_open: false)}
  end

  def handle_info(:close_file_drawer, socket) do
    {:noreply, assign(socket, file_drawer_open: false)}
  end

  def handle_info(:reload_kin_agents, socket) do
    {:noreply, assign(socket, kin_agents: load_kin_agents())}
  end

  def handle_info({:spawn_kin_agent, kin}, socket) do
    team_id = socket.assigns[:active_team_id]

    if team_id do
      spawn_opts = [project_path: socket.assigns[:project_path]]

      spawn_opts =
        if kin.model_override,
          do: [{:model, kin.model_override} | spawn_opts],
          else: spawn_opts

      Loomkin.Teams.Manager.spawn_agent(team_id, kin.name, kin.role, spawn_opts)
    end

    {:noreply, socket}
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

    if team_id = socket.assigns[:team_id] do
      Teams.Manager.update_all_models(team_id, model)
    end

    {:noreply, assign(socket, model: model)}
  end

  def handle_info({:change_fast_model, model}, socket) do
    Session.update_fast_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, fast_model: model)}
  end

  def handle_info(:new_session, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_info({:new_session_for_project, path}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/new?#{%{project_path: path}}")}
  end

  def handle_info({:select_session, session_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{session_id}")}
  end

  def handle_info({:permission_response, action, request_id}, socket) do
    {request, remaining} =
      pop_permission_request(socket.assigns.pending_permissions, request_id)

    if request do
      route_permission_response(socket, action, request)
    end

    {:noreply, assign(socket, pending_permissions: remaining)}
  end

  def handle_info({:permission_batch_action, action, scope}, socket) do
    {to_act, to_keep} = split_permissions_by_scope(socket.assigns.pending_permissions, scope)

    for request <- to_act do
      route_permission_response(socket, action, request)
    end

    {:noreply, assign(socket, pending_permissions: to_keep)}
  end

  # Legacy 4-arg format (from old PermissionComponent)
  def handle_info({:permission_response, action, tool_name, tool_path}, socket) do
    {request, remaining} =
      pop_permission_request_by_tool(
        socket.assigns.pending_permissions,
        tool_name,
        tool_path
      )

    if request do
      route_permission_response(socket, action, request)
    end

    {:noreply, assign(socket, pending_permissions: remaining)}
  end

  # Team PubSub events -- forward to team components via send_update
  def handle_info({:agent_status, agent_name, status, metadata}, socket) do
    forward_to_team_components(socket)

    socket =
      socket
      |> schedule_roster_refresh()
      |> update_card_status(agent_name, status, metadata)
      |> forward_to_cards_and_comms({:agent_status, agent_name, status})
      |> maybe_insert_synthesis_comms_event(agent_name, status, metadata)

    {:noreply, forward_to_activity(socket, {:agent_status, agent_name, status})}
  end

  def handle_info({:agent_status, agent_name, status} = event, socket) do
    forward_to_team_components(socket)

    socket =
      socket
      |> schedule_roster_refresh()
      |> update_card_status(agent_name, status)
      |> forward_to_cards_and_comms(event)

    {:noreply, forward_to_activity(socket, event)}
  end

  def handle_info({:task_created, _task_id, _title} = event, socket) do
    forward_to_dashboard(socket)

    {:noreply,
     socket
     |> schedule_roster_refresh()
     |> forward_to_activity(event)
     |> forward_to_cards_and_comms(event)
     |> refresh_task_graph()}
  end

  def handle_info({:task_assigned, task_id, agent_name} = event, socket) do
    forward_to_dashboard(socket)

    # Look up task title from cached_tasks
    task_title =
      Enum.find_value(socket.assigns.cached_tasks, "Assigned task", fn t ->
        if t.id == task_id, do: t.title
      end)

    # Enrich with capability reasoning for smart assignment transparency
    team_id = socket.assigns[:active_team_id]
    enriched_event = enrich_task_assigned(event, task_title, team_id)

    socket =
      socket
      |> schedule_roster_refresh()
      |> forward_to_activity(enriched_event)
      |> forward_to_cards_and_comms(enriched_event)
      |> update_card_task(agent_name, task_title)
      |> refresh_task_graph()

    {:noreply, socket}
  end

  def handle_info({:task_completed, _task_id, agent_name, _result} = event, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)

    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
      |> update_card_task(agent_name, nil)
      |> refresh_task_graph()

    {:noreply, socket}
  end

  def handle_info({:task_started, _task_id, owner} = event, socket) do
    forward_to_dashboard(socket)

    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
      |> update_card_status(owner, :working)
      |> refresh_task_graph()

    {:noreply, socket}
  end

  def handle_info({:task_failed, _task_id, owner, _reason} = event, socket) do
    forward_to_dashboard(socket)

    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
      |> update_card_status(owner, :error)
      |> refresh_task_graph()

    {:noreply, socket}
  end

  def handle_info({:role_changed, agent_name, _old, new_role} = event, socket) do
    forward_to_dashboard(socket)

    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
      |> update_agent_card(agent_name, %{role: new_role})

    {:noreply, socket}
  end

  def handle_info({:agent_escalation, _agent_name, _old, _new} = event, socket) do
    forward_to_dashboard(socket)
    forward_to_cost(socket)

    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:usage, agent_name, payload}, socket) do
    forward_to_cost(socket)
    {:noreply, update_card_budget(socket, agent_name, payload)}
  end

  # Agent error events (max iterations exceeded, tool failures, etc.)
  def handle_info({:agent_error, agent_name, _payload} = event, socket) do
    socket =
      socket
      |> forward_to_activity(event)
      |> forward_to_cards_and_comms(event)
      |> update_card_status(agent_name, :error)

    {:noreply, socket}
  end

  # Agent streaming events — show thoughts live in activity feed + agent cards
  def handle_info({:agent_stream_start, agent_name, _payload}, socket) do
    card = get_in(socket.assigns, [:agent_cards, agent_name])
    # Clear stuck :error status — if the agent is streaming it has recovered and is working
    status_update = if card && card.status == :error, do: %{status: :working}, else: %{}

    socket =
      update_agent_card(
        socket,
        agent_name,
        Map.merge(status_update, %{
          content_type: :thinking,
          latest_content: ""
        })
      )

    {:noreply, socket}
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

    # Accumulate content on the card only — no activity_events mutation on the hot path
    card = get_in(socket.assigns, [:agent_cards, agent_name])
    current = (card && card.latest_content) || ""
    updated = current <> chunk

    socket =
      update_agent_card(socket, agent_name, %{
        latest_content: updated,
        content_type: :thinking
      })

    {:noreply, socket}
  end

  def handle_info({:agent_stream_end, agent_name, _payload}, socket) do
    # Preserve :message content — only reset to :idle if currently :thinking
    card = get_in(socket.assigns, [:agent_cards, agent_name])

    socket =
      cond do
        card && card.content_type == :message ->
          socket

        card && card.content_type == :thinking && card.latest_content not in [nil, ""] ->
          # Keep the last thinking content visible (dimmed) while tools run
          update_agent_card(socket, agent_name, %{
            content_type: :last_thinking
          })

        true ->
          update_agent_card(socket, agent_name, %{
            content_type: :idle
          })
      end

    {:noreply, socket}
  end

  def handle_info({:child_team_created, child_team_id, parent_team_id, team_name}, socket) do
    require Logger
    Logger.info("[Kin:UI] :child_team_created child=#{child_team_id} parent=#{parent_team_id}")

    tree = socket.assigns.team_tree

    updated_tree =
      if child_team_id in Map.get(tree, parent_team_id, []) do
        tree
      else
        Map.update(tree, parent_team_id, [child_team_id], &[child_team_id | &1])
      end

    updated_names = Map.put(socket.assigns.team_names, child_team_id, team_name)

    existing_card_names = Map.keys(socket.assigns.agent_cards)

    socket =
      socket
      |> subscribe_to_team(child_team_id)
      |> assign(:team_tree, updated_tree)
      |> assign(:team_names, updated_names)
      |> refresh_roster()
      |> sync_cards_with_roster()

    # Generate "joined" comms events for newly-discovered agents
    new_agents =
      socket.assigns.cached_agents
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in existing_card_names))

    socket =
      Enum.reduce(new_agents, socket, fn agent_name, sock ->
        event = %{
          id: Ecto.UUID.generate(),
          type: :agent_spawn,
          agent: agent_name,
          content: "#{agent_name} joined",
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: %{team_id: child_team_id}
        }

        sock
        |> stream_insert(:comms_events, event)
        |> update(:comms_event_count, &(&1 + 1))
      end)

    {:noreply, socket}
  end

  def handle_info({:team_dissolved, team_id}, socket) do
    if team_id == socket.assigns.team_id do
      # Clean up broadcaster for the root team
      if broadcaster = socket.assigns[:broadcaster] do
        TeamBroadcaster.remove_team(broadcaster, team_id)
      end

      {:noreply,
       assign(socket,
         team_id: nil,
         team_tree: %{},
         team_names: %{},
         active_team_id: nil,
         active_tab: :files,
         mode: :solo,
         focused_agent: nil,
         inspector_mode: :auto_follow,
         subscribed_teams: MapSet.new()
       )}
    else
      # Find all descendants and unsubscribe from each
      descendants = collect_descendants(socket.assigns.team_tree, team_id)
      all_to_remove = [team_id | descendants]

      Enum.each(all_to_remove, fn tid ->
        Phoenix.PubSub.unsubscribe(Loomkin.PubSub, Topics.team_pubsub(tid))
      end)

      # Remove dissolved teams from broadcaster filter set
      if broadcaster = socket.assigns[:broadcaster] do
        Enum.each(all_to_remove, fn tid ->
          TeamBroadcaster.remove_team(broadcaster, tid)
        end)
      end

      updated_tree =
        Enum.reduce(all_to_remove, socket.assigns.team_tree, &remove_from_tree(&2, &1))

      updated_names = Map.drop(socket.assigns.team_names, all_to_remove)

      active_team_id =
        if socket.assigns.active_team_id == team_id,
          do: socket.assigns.team_id,
          else: socket.assigns.active_team_id

      # Switch back to solo if no teams remain
      mode =
        if updated_tree == %{} && socket.assigns.team_id == nil,
          do: :solo,
          else: socket.assigns.mode

      updated_subscribed =
        MapSet.difference(
          socket.assigns[:subscribed_teams] || MapSet.new(),
          MapSet.new(all_to_remove)
        )

      {:noreply,
       assign(socket,
         team_tree: updated_tree,
         team_names: updated_names,
         active_team_id: active_team_id,
         mode: mode,
         subscribed_teams: updated_subscribed
       )}
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

  # Debounced metrics refresh — fired by Process.send_after from system.metrics.updated handler
  def handle_info(:refresh_metrics, socket) do
    socket = assign(socket, metrics_debounce_ref: nil)
    handle_info(:metrics_updated, socket)
  end

  # Handle async task completion — match on the stored async_task ref
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case socket.assigns[:async_task] do
      %Task{ref: ^ref} ->
        socket =
          case result do
            {:ok, _response} ->
              assign(socket, failed_message_idx: nil)

            {:error, :cancelled} ->
              # User-initiated cancel — no error flash needed
              assign(socket,
                streaming: false,
                streaming_content: "",
                streaming_agent: nil,
                failed_message_idx: nil
              )

            {:error, :busy} ->
              # Agent is busy with another task — show a gentle warning
              socket
              |> assign(
                streaming: false,
                streaming_content: "",
                streaming_agent: nil,
                failed_message_idx: nil
              )
              |> put_flash(:info, "Agent is busy — try again in a moment")

            {:error, reason} ->
              failed_idx =
                socket.assigns.messages
                |> Enum.with_index()
                |> Enum.filter(fn {msg, _} -> msg.role == :user end)
                |> List.last()
                |> case do
                  {_, idx} -> idx
                  nil -> nil
                end

              messages =
                if failed_idx != nil do
                  List.update_at(socket.assigns.messages, failed_idx, &Map.put(&1, :failed, true))
                else
                  socket.assigns.messages
                end

              socket
              |> assign(
                streaming: false,
                streaming_content: "",
                streaming_agent: nil,
                failed_message_idx: failed_idx,
                messages: messages
              )
              |> put_flash(:error, format_llm_error(reason))

            _other ->
              socket
          end

        {:noreply, assign(socket, async_task: nil, status: :idle)}

      _ ->
        # Not our task — ignore
        {:noreply, socket}
    end
  end

  def handle_info({:resend_message, content}, socket) do
    session_id = socket.assigns.session_id
    failed_idx = socket.assigns.failed_message_idx

    messages =
      if failed_idx != nil do
        List.update_at(socket.assigns.messages, failed_idx, &Map.delete(&1, :failed))
      else
        socket.assigns.messages
      end

    task =
      Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
        Session.send_message(session_id, content)
      end)

    {:noreply,
     assign(socket,
       async_task: task,
       status: :thinking,
       messages: messages,
       failed_message_idx: nil
     )}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) when is_reference(ref) do
    case socket.assigns[:async_task] do
      %Task{ref: ^ref} ->
        {:noreply, assign(socket, async_task: nil, status: :idle)}

      _ ->
        {:noreply, socket}
    end
  end

  # Team decision and context events — refresh graph + buffer for activity feed + comms
  def handle_info({:decision_logged, _node_id, _agent_name} = event, socket) do
    refresh_decision_graphs(socket)
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:node_added, _node} = event, socket) do
    refresh_decision_graphs(socket)
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:pivot_created, _result} = event, socket) do
    refresh_decision_graphs(socket)
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:context_update, _from_agent, _payload} = event, socket) do
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:context_offloaded, _agent_name, _payload} = event, socket) do
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  # Focus/pin an agent in the inspector panel
  def handle_info({:focus_agent, agent_name}, socket) do
    {:noreply, assign(socket, focused_agent: agent_name, inspector_mode: :pinned)}
  end

  # Set reply target for the message composer
  def handle_info({:reply_to_agent, agent_name, team_id}, socket) do
    {:noreply, assign(socket, reply_target: %{agent: agent_name, team_id: team_id})}
  end

  # Pause/Resume/Steer agent actions from card controls
  def handle_info({:pause_agent, agent_name, team_id}, socket) do
    case find_agent_pid(socket, agent_name, team_id) do
      {:ok, pid} ->
        Loomkin.Teams.Agent.request_pause(pid)

      :error ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_info({:resume_agent, agent_name, team_id}, socket) do
    # Redirect resume to steer flow — resuming requires mandatory guidance text
    send(self(), {:steer_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_info({:steer_agent, agent_name, team_id}, socket) do
    # Set reply_target to the agent so the user can type guidance in the composer
    # When they submit, it will be sent as steering guidance
    {:noreply,
     assign(socket,
       reply_target: %{agent: agent_name, team_id: team_id, mode: :steer},
       focused_agent: agent_name,
       inspector_mode: :pinned
     )}
  end

  def handle_info({:unpin_agent}, socket) do
    {:noreply, assign(socket, focused_agent: nil, inspector_mode: :auto_follow)}
  end

  def handle_info({:resume_follow}, socket) do
    {:noreply, assign(socket, inspector_mode: :auto_follow)}
  end

  # From activity feed file clicks — open the file drawer
  def handle_info({:inspector_file, path}, socket) do
    {:noreply, assign(socket, selected_file: path, file_drawer_open: true)}
  end

  # New event types for activity feed
  def handle_info({:keeper_created, _payload} = event, socket) do
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  def handle_info({:tasks_unblocked, _task_ids} = event, socket) do
    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  # --- Ask User questions from agents ---

  def handle_info({:ask_user_question, question}, socket) do
    questions = [question | socket.assigns.pending_questions]

    event = %{
      id: Ecto.UUID.generate(),
      type: :ask_user,
      agent: question.agent_name,
      content: question.question,
      timestamp: DateTime.utc_now(),
      expanded: true,
      metadata: %{question_id: question.question_id, options: question.options}
    }

    # Build the updated pending_questions list for the agent card
    card = get_in(socket.assigns.agent_cards, [question.agent_name]) || %{}
    existing_card_questions = card[:pending_questions] || []

    new_card_entry = %{
      question_id: question.question_id,
      question: question.question,
      options: question.options,
      agent_name: question.agent_name
    }

    updated_card_questions = existing_card_questions ++ [new_card_entry]

    socket =
      socket
      |> assign(pending_questions: questions)
      |> append_activity_event(event)
      |> update_agent_card(question.agent_name, %{
        pending_questions: updated_card_questions
      })

    {:noreply, socket}
  end

  def handle_info({:ask_user_answered, question_id, answer}, socket) do
    remaining = Enum.reject(socket.assigns.pending_questions, &(&1.question_id == question_id))

    # Clear pending_questions from the agent's card when this was the last question
    agent_name =
      Enum.find_value(socket.assigns.pending_questions, fn q ->
        if q.question_id == question_id, do: q.agent_name
      end)

    socket =
      if agent_name do
        agent_remaining = Enum.filter(remaining, &(&1.agent_name == agent_name))

        card = get_in(socket.assigns.agent_cards, [agent_name]) || %{}

        card_questions =
          (card[:pending_questions] || []) |> Enum.reject(&(&1.question_id == question_id))

        socket = update_agent_card(socket, agent_name, %{pending_questions: card_questions})

        if agent_remaining == [] do
          update_agent_card(socket, agent_name, %{pending_questions: []})
        else
          socket
        end
      else
        socket
      end

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

    event = {:collab_event, payload}

    {:noreply, socket |> forward_to_activity(event) |> forward_to_cards_and_comms(event)}
  end

  # Periodic collaboration health score refresh (every 10s while session active)
  def handle_info(:refresh_collab_health, socket) do
    socket =
      if team_id = socket.assigns[:team_id] do
        score = Loomkin.Teams.CollaborationMetrics.collaboration_score(team_id)
        assign(socket, collab_health: score)
      else
        socket
      end

    {:noreply, schedule_collab_health_refresh(socket)}
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
  # --- Queue & Schedule PubSub ---

  def handle_info({:queue_updated, agent_name, queue}, socket) do
    agent_queues = Map.put(socket.assigns.agent_queues, agent_name, queue)
    {:noreply, assign(socket, agent_queues: agent_queues)}
  end

  def handle_info({:schedule_updated, _team_id, scheduled}, socket) do
    {:noreply, assign(socket, scheduled_messages: scheduled)}
  end

  def handle_info({:scheduled_delivered, _message_id, agent_name}, socket) do
    {:noreply, put_flash(socket, :info, "Scheduled message delivered to #{agent_name}")}
  end

  # --- Forwarded component events ---

  # Command palette actions forwarded from CommandPaletteComponent
  def handle_info({:command_palette_action, "agent", agent_name}, socket) do
    {:noreply, assign(socket, focused_agent: agent_name, inspector_mode: :pinned)}
  end

  def handle_info({:command_palette_action, "tab", _tab}, socket) do
    {:noreply, assign(socket, file_drawer_open: true)}
  end

  def handle_info({:command_palette_action, "sub_tab", tab}, socket) do
    {:noreply, assign(socket, team_sub_tab: String.to_existing_atom(tab))}
  end

  def handle_info({:command_palette_action, "action", "toggle_mode"}, socket) do
    new_mode = if socket.assigns.mode == :solo, do: :mission_control, else: :solo
    {:noreply, assign(socket, mode: new_mode)}
  end

  def handle_info({:command_palette_action, "action", "switch_project"}, socket) do
    {:noreply,
     assign(socket,
       switch_project_modal: %{
         phase: :input,
         target_path: socket.assigns.explorer_path,
         active_agents: []
       }
     )}
  end

  def handle_info({:command_palette_action, "action", "focus_input"}, socket) do
    {:noreply, push_event(socket, "focus-input", %{})}
  end

  def handle_info({:command_palette_action, "action", "refresh_channels"}, socket) do
    team_id = socket.assigns[:active_team_id]
    bindings = load_channel_bindings(team_id)
    {:noreply, assign(socket, channel_bindings: bindings)}
  end

  def handle_info({:command_palette_action, _type, _value}, socket) do
    {:noreply, socket}
  end

  # Composer events forwarded from ComposerComponent
  def handle_info({:composer_event, "send_message", params}, socket) do
    handle_event("send_message", params, socket)
  end

  def handle_info({:composer_event, "cancel_reply", _params}, socket) do
    {:noreply, assign(socket, reply_target: nil)}
  end

  def handle_info({:composer_event, "select_reply_target", %{"agent" => "team"}}, socket) do
    {:noreply, assign(socket, reply_target: nil, broadcast_mode: true)}
  end

  def handle_info(
        {:composer_event, "select_reply_target", %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    {:noreply,
     assign(socket, reply_target: %{agent: agent_name, team_id: team_id}, broadcast_mode: false)}
  end

  def handle_info({:composer_event, "toggle_queue_from_composer", _params}, socket) do
    case socket.assigns.reply_target do
      %{agent: agent_name, team_id: team_id} ->
        {:noreply, assign(socket, queue_drawer: %{agent: agent_name, team_id: team_id})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:composer_event, "enqueue_message", _params}, socket) do
    handle_event("enqueue_message", %{}, socket)
  end

  def handle_info({:composer_event, "inject_guidance", _params}, socket) do
    handle_event("inject_guidance", %{}, socket)
  end

  def handle_info({:composer_event, _event, _params}, socket) do
    {:noreply, socket}
  end

  # Sidebar events forwarded from SidebarPanelComponent
  def handle_info({:sidebar_event, "switch_tab", %{"tab" => tab}}, socket) do
    handle_event("switch_tab", %{"tab" => tab}, socket)
  end

  def handle_info({:sidebar_event, "deselect_file", _params}, socket) do
    {:noreply, assign(socket, selected_file: nil, file_content: nil)}
  end

  def handle_info({:sidebar_event, "edit_explorer_path", _params}, socket) do
    {:noreply, assign(socket, editing_explorer_path: true)}
  end

  def handle_info({:sidebar_event, "cancel_edit_explorer", _params}, socket) do
    {:noreply, assign(socket, editing_explorer_path: false)}
  end

  def handle_info({:sidebar_event, "set_explorer_path", params}, socket) do
    handle_event("set_explorer_path", params, socket)
  end

  def handle_info({:sidebar_event, _event, _params}, socket) do
    {:noreply, socket}
  end

  # Mission control events forwarded from MissionControlPanelComponent
  def handle_info({:mission_control_event, "focus_card_agent", %{"agent" => agent_name}}, socket) do
    send(self(), {:focus_agent, agent_name})
    {:noreply, socket}
  end

  def handle_info({:mission_control_event, "unfocus_agent", _params}, socket) do
    {:noreply, assign(socket, focused_agent: nil, inspector_mode: :auto_follow)}
  end

  def handle_info(
        {:mission_control_event, "reply_to_card_agent",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    send(self(), {:reply_to_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_info(
        {:mission_control_event, "pause_card_agent",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    send(self(), {:pause_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_info(
        {:mission_control_event, "resume_card_agent",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    send(self(), {:resume_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_info(
        {:mission_control_event, "steer_card_agent",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    send(self(), {:steer_agent, agent_name, team_id})
    {:noreply, socket}
  end

  def handle_info(
        {:mission_control_event, "force_pause_card_agent",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    case find_agent_pid(socket, agent_name, team_id) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.force_pause(pid)
        end)

      :error ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_info(
        {:mission_control_event, "open_queue_drawer",
         %{"agent" => agent_name, "team-id" => team_id}},
        socket
      ) do
    {:noreply, assign(socket, queue_drawer: %{agent: agent_name, team_id: team_id})}
  end

  def handle_info({:mission_control_event, "spawn_dormant_kin", %{"id" => id}}, socket) do
    handle_event("spawn_dormant_kin", %{"id" => id}, socket)
  end

  def handle_info({:mission_control_event, _event, _params}, socket) do
    {:noreply, socket}
  end

  # --- Queue drawer actions (delegated from MessageQueueComponent) ---

  def handle_info({:queue_action, :close_drawer}, socket) do
    {:noreply, assign(socket, queue_drawer: nil)}
  end

  def handle_info(
        {:queue_action, :save_edit, agent_name, team_id, %{id: id, content: content}},
        socket
      ) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} -> Loomkin.Teams.Agent.edit_queued(pid, id, content)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:queue_action, :delete, agent_name, team_id, id}, socket) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} -> Loomkin.Teams.Agent.delete_queued(pid, id)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:queue_action, :delete_selected, agent_name, team_id, ids}, socket) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} -> Enum.each(ids, fn id -> Loomkin.Teams.Agent.delete_queued(pid, id) end)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:queue_action, :squash, agent_name, team_id, ids}, socket) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} -> Loomkin.Teams.Agent.squash_queued(pid, ids)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:queue_action, :reorder, agent_name, team_id, ordered_ids}, socket) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} -> Loomkin.Teams.Agent.reorder_queue(pid, :pending, ordered_ids)
      :error -> :ok
    end

    {:noreply, socket}
  end

  # Clear recovering status back to idle after 2s delay
  def handle_info({:clear_recovering, agent_name}, socket) do
    card = get_in(socket.assigns, [:agent_cards, agent_name])

    if card && card.status == :recovering do
      {:noreply, update_card_status(socket, agent_name, :idle)}
    else
      {:noreply, socket}
    end
  end

  # Remove terminated agent card after animation completes
  def handle_info({:remove_terminated_card, agent_name}, socket) do
    cards = Map.delete(socket.assigns.agent_cards, agent_name)

    socket =
      socket
      |> assign(agent_cards: cards)
      |> update_card_ordering()

    {:noreply, socket}
  end

  # Catch-all
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("[Kin:UI] unhandled msg=#{inspect(msg, limit: 100)}")
    {:noreply, socket}
  end

  # Dispatches a signal inline, returning the updated socket.
  # Used by team_broadcast handlers to avoid extra mailbox hops.
  defp dispatch_signal(%Jido.Signal{} = sig, socket) do
    socket =
      try do
        case handle_info(sig, socket) do
          {:noreply, socket} -> socket
          _ -> socket
        end
      rescue
        e ->
          require Logger
          Logger.warning("[Kin:UI] dispatch_signal crashed on #{sig.type}: #{inspect(e)}")
          socket
      end

    # Append to debug signal log (capped at 50)
    entry = %{
      type: sig.type,
      at: System.system_time(:millisecond),
      agent: get_in(sig.data, [:agent_name]) || get_in(sig.data, [:name]) || "system"
    }

    debug_signals = Enum.take([entry | socket.assigns.debug_signals], 50)

    # Auto-open debug panel on first signal
    socket =
      if socket.assigns.debug_signals == [] and not socket.assigns.debug_panel_open do
        assign(socket, :debug_panel_open, true)
      else
        socket
      end

    assign(socket, :debug_signals, debug_signals)
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <%!-- Workspace state: persists UI layout to localStorage so reloads don't reset --%>
    <div
      id="workspace-state"
      phx-hook="WorkspaceState"
      data-session-id={@session_id}
      data-mode={@mode}
      data-active-tab={@active_tab}
      data-focused-agent={@focused_agent}
      data-inspector-mode={@inspector_mode}
      data-collapsed-inspector={to_string(@collapsed_inspector)}
      class="hidden"
    />

    <%!-- Session memory: persists active session to localStorage so reloads snap back --%>
    <div
      id="session-memory"
      phx-hook="SessionMemory"
      data-session-id={@session_id}
      data-project-path={@project_path}
      class="hidden"
    />

    <div
      class="flex flex-col h-screen overflow-hidden bg-surface-0 gradient-mesh text-gray-100"
      phx-hook="KeyboardShortcuts"
      id="workspace-shortcuts"
    >
      <%!-- Permission Dashboard --%>
      <.live_component
        :if={@pending_permissions != []}
        module={LoomkinWeb.PermissionDashboardComponent}
        id="permission-dashboard"
        pending_permissions={@pending_permissions}
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
      <.live_component
        module={LoomkinWeb.CommandPaletteComponent}
        id="command-palette"
        agents={@cached_agents}
      />

      <%!-- ── Header ── --%>
      <header class="flex-shrink-0 flex items-center gap-3 px-3 py-1.5 sm:px-4 lg:px-5 relative bg-surface-1 border-b border-subtle z-50">
        <%!-- Brand mark — pulses when system is active --%>
        <a
          href="/"
          aria-label="Loomkin"
          class={[
            "flex items-center gap-2 flex-shrink-0 group",
            @status in [:thinking, :executing_tool] && "brand-active"
          ]}
          title={status_label(@status, @current_tool_name)}
        >
          <svg
            class="w-5 h-5 transition-transform duration-200 group-hover:scale-110"
            viewBox="0 0 32 32"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
            aria-hidden="true"
          >
            <polygon points="10,2 6,10 15,7" fill="#5B21B6" />
            <polygon points="22,2 26,10 17,7" fill="#5B21B6" />
            <polygon points="6,10 4,20 12,15" fill="#4B0082" />
            <polygon points="26,10 28,20 20,15" fill="#4B0082" />
            <polygon points="12,15 16,7 20,15" fill="#7C3AED" />
            <polygon points="12,15 16,24 20,15" fill="#4B0082" />
            <circle cx="12" cy="14" r="3" fill="#F59E0B" />
            <circle cx="20" cy="14" r="3" fill="#F59E0B" />
          </svg>
        </a>

        <%!-- Thinking model selector --%>
        <.live_component
          module={LoomkinWeb.ModelSelectorComponent}
          id="thinking-model-selector"
          model={@model}
          selector_mode={:thinking}
        />

        <%!-- Fast model selector --%>
        <.live_component
          module={LoomkinWeb.ModelSelectorComponent}
          id="fast-model-selector"
          model={@fast_model || @model}
          selector_mode={:fast}
        />

        <%!-- Trust policy selector --%>
        <LoomkinWeb.TrustPolicyComponent.trust_policy_selector
          current_preset={@trust_preset}
          pending_count={length(@pending_permissions)}
          expanded={@trust_expanded}
          class="hidden md:flex"
        />

        <%!-- Project pill --%>
        <button
          phx-click="initiate_switch_project"
          class="hidden md:flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[11px] interactive press-down text-secondary"
          title={@project_path}
        >
          <span class="relative flex h-1.5 w-1.5 flex-shrink-0">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-40">
            </span>
            <span class="relative inline-flex rounded-full h-1.5 w-1.5 bg-emerald-500"></span>
          </span>
          <span class="font-mono truncate max-w-[8rem]">{Path.basename(@project_path)}</span>
        </button>

        <%!-- Team indicator (mission control mode) --%>
        <div
          :if={@mode == :mission_control && @active_team_id}
          class="hidden md:flex items-center gap-1.5"
        >
          <div class="flex items-center gap-1 px-2 py-0.5 rounded-md bg-brand-subtle">
            <span class="text-brand">
              <.icon name="hero-user-group-mini" class="w-3 h-3" />
            </span>
            <span class="text-[11px] font-medium text-brand">
              {length(@cached_agents)}
            </span>
          </div>
          <.live_component
            module={LoomkinWeb.TeamTreeComponent}
            id="team-tree"
            team_tree={@team_tree}
            root_team_id={@team_id}
            active_team_id={@active_team_id}
            agent_counts={compute_agent_counts(@cached_agents)}
            team_names={@team_names}
          />
        </div>

        <%!-- Spacer --%>
        <div class="flex-1"></div>

        <%!-- Right: Controls --%>
        <div class="flex items-center gap-1">
          <%!-- Cost --%>
          <a
            href="/dashboard"
            class="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] transition-all duration-200 interactive text-muted"
            title="View dashboard"
          >
            <span class="font-mono text-secondary">
              ${format_cost(@session_cost)}
            </span>
            <span class="hidden font-mono sm:inline text-muted text-[10px]">
              {format_tokens(@session_tokens)}t
            </span>
          </a>

          <%!-- File Explorer --%>
          <button
            phx-click="toggle_file_drawer"
            class={[
              "flex items-center gap-1 px-1.5 py-0.5 rounded-md text-[11px] transition-colors hover:bg-surface-2",
              if(@file_drawer_open, do: "text-brand", else: "text-muted")
            ]}
            data-tooltip="Files & diffs"
            aria-label="Files & diffs"
          >
            <.icon name="hero-folder-open-mini" class="w-3.5 h-3.5" />
          </button>

          <%!-- Kin Management --%>
          <button
            phx-click="open_kin_panel"
            class="flex items-center gap-1 px-1.5 py-0.5 rounded-md text-[11px] transition-colors hover:bg-surface-2 text-muted"
            data-tooltip="Manage kin templates"
            aria-label="Manage kin templates"
          >
            <svg class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path d="M7 8a3 3 0 100-6 3 3 0 000 6zM14.5 9a2.5 2.5 0 100-5 2.5 2.5 0 000 5zM1.615 16.428a1.224 1.224 0 01-.569-1.175 6.002 6.002 0 0111.908 0c.058.467-.172.92-.57 1.174A9.953 9.953 0 017 18a9.953 9.953 0 01-5.385-1.572zM14.5 16h-.106c.07-.297.088-.611.048-.933a7.47 7.47 0 00-1.588-3.755 4.502 4.502 0 015.874 2.636.818.818 0 01-.36.98A7.465 7.465 0 0114.5 16z" />
            </svg>
          </button>

          <%!-- Session switcher --%>
          <.live_component
            module={LoomkinWeb.SessionSwitcherComponent}
            id="session-switcher"
            session_id={@session_id}
            project_path={@project_path}
          />
        </div>
      </header>

      <%!-- Status Banner — always visible, loud indicators for debugging --%>
      <div class={[
        "flex-shrink-0 flex items-center gap-4 px-4 py-2 border-b text-sm font-medium",
        if(@status in [:thinking, :executing_tool, :streaming],
          do: "bg-violet-950/80 border-violet-500/40",
          else: "bg-surface-1 border-subtle"
        )
      ]}>
        <%!-- Status pill — large and color-coded --%>
        <span class={status_banner_class(@status)}>
          {status_label(@status, @current_tool_name)}
        </span>

        <%!-- Architect phase — bold amber --%>
        <span
          :if={@architect_phase}
          class="flex items-center gap-1.5 text-amber-300 font-mono font-bold"
        >
          <span class="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
          {@architect_phase}
        </span>

        <%!-- Current tool — bold blue with spinner --%>
        <span
          :if={@current_tool}
          class="flex items-center gap-1.5 text-blue-300 font-mono font-bold truncate max-w-[40%]"
        >
          <svg
            class="animate-spin h-3.5 w-3.5 text-blue-400 flex-shrink-0"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
            >
            </path>
          </svg>
          {@current_tool}
        </span>

        <%!-- Streaming indicator — green pulse --%>
        <span :if={@streaming} class="flex items-center gap-1.5 text-emerald-300 font-bold">
          <span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span> streaming
        </span>

        <%!-- Agent count --%>
        <span :if={@cached_agents != []} class="flex items-center gap-1 text-purple-300">
          <span class="text-purple-400">{length(@cached_agents)}</span> agents
        </span>

        <%!-- Debug panel toggle — right-aligned with signal count badge --%>
        <button
          phx-click="toggle_debug_panel"
          class={[
            "ml-auto flex items-center gap-1.5 px-2.5 py-1 rounded-md transition-colors",
            if(@debug_panel_open,
              do: "bg-violet-600/30 text-violet-300",
              else: "hover:bg-surface-2 text-zinc-400 hover:text-zinc-200"
            )
          ]}
        >
          <span class="text-xs">signals</span>
          <span class={[
            "inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1 rounded-full text-[11px] font-bold",
            if(length(@debug_signals) > 0,
              do: "bg-violet-500/40 text-violet-200",
              else: "bg-zinc-700 text-zinc-500"
            )
          ]}>
            {length(@debug_signals)}
          </span>
        </button>
      </div>

      <%!-- ── Main Content — branches on mode ── --%>
      <div id="main-content" class="flex flex-1 min-h-0 flex-col xl:flex-row">
        <%= if @mode == :solo do %>
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
                streaming_agent={@streaming_agent}
                architect_phase={@architect_phase}
                plan_steps={@plan_steps}
                current_step={@current_step}
                failed_message_idx={@failed_message_idx}
              />
            </div>

            <%!-- Pending ask_user questions (also shown in solo mode) --%>
            <div
              :if={@pending_questions != []}
              class="flex-shrink-0 px-3 py-2 border-t border-brand bg-surface-1"
            >
              <.live_component
                module={LoomkinWeb.AskUserComponent}
                id="ask-user-questions-solo"
                questions={@pending_questions}
              />
            </div>

            <.live_component
              module={LoomkinWeb.ComposerComponent}
              id="composer"
              input_text={@input_text}
              reply_target={Map.get(assigns, :reply_target)}
              cached_agents={@cached_agents}
              cached_budget={@cached_budget}
              budget_pct={@budget_pct}
              budget_bar_color_class={@budget_bar_color_class}
              last_user_message={@last_user_message}
              queue_drawer={@queue_drawer}
              scheduled_messages={@scheduled_messages}
              agent_queues={@agent_queues}
              active_team_id={@active_team_id}
              session_id={@session_id}
              status={@status}
              agent_cards={@agent_cards}
            />
          </div>

          <%!-- Right: Sidebar --%>
          <.live_component
            module={LoomkinWeb.SidebarPanelComponent}
            id="sidebar-panel"
            active_tab={@active_tab}
            selected_file={@selected_file}
            file_content={@file_content}
            diffs={@diffs}
            file_tree_version={@file_tree_version}
            session_id={@session_id}
            active_team_id={@active_team_id}
            explorer_path={@explorer_path || @project_path}
            project_path={@project_path}
          />
        <% else %>
          <%!-- Mission Control Left: Agent Cards + Comms + Composer --%>
          <div class="flex-1 flex flex-col min-w-0 min-h-0 border-r border-subtle overflow-hidden">
            <.live_component
              module={LoomkinWeb.MissionControlPanelComponent}
              id="mission-control-panel"
              agent_cards={@agent_cards}
              concierge_card_names={@concierge_card_names}
              system_card_names={@system_card_names}
              worker_card_names={@worker_card_names}
              comms_event_count={@comms_event_count}
              comms_stream={@streams.comms_events}
              focused_agent={@focused_agent}
              kin_agents={@kin_agents}
              cached_agents={@cached_agents}
              active_team_id={@active_team_id}
              leader_approval_pending={@leader_approval_pending}
              collab_health={@collab_health}
            />

            <%!-- Chat + Composer column --%>
            <div class="flex-shrink-0 flex flex-col min-w-0 border-r border-subtle">
              <div class="flex-1 overflow-auto min-h-0">
                <.live_component
                  module={LoomkinWeb.ChatComponent}
                  id="chat"
                  messages={@messages}
                  status={@status}
                  current_tool={@current_tool}
                  streaming={@streaming}
                  streaming_content={@streaming_content}
                  streaming_agent={@streaming_agent}
                  architect_phase={@architect_phase}
                  plan_steps={@plan_steps}
                  current_step={@current_step}
                  failed_message_idx={@failed_message_idx}
                />
              </div>

              <%!-- Pending ask_user questions --%>
              <div
                :if={@pending_questions != []}
                class="flex-shrink-0 px-3 py-2 border-t border-brand bg-surface-1"
              >
                <.live_component
                  module={LoomkinWeb.AskUserComponent}
                  id="ask-user-questions-mc"
                  questions={@pending_questions}
                />
              </div>

              <.live_component
                module={LoomkinWeb.ComposerComponent}
                id="composer"
                input_text={@input_text}
                reply_target={Map.get(assigns, :reply_target)}
                cached_agents={@cached_agents}
                cached_budget={@cached_budget}
                budget_pct={@budget_pct}
                budget_bar_color_class={@budget_bar_color_class}
                last_user_message={@last_user_message}
                queue_drawer={@queue_drawer}
                scheduled_messages={@scheduled_messages}
                agent_queues={@agent_queues}
                active_team_id={@active_team_id}
                session_id={@session_id}
                status={@status}
                agent_cards={@agent_cards}
                broadcast_mode={@broadcast_mode}
                agent_count={length(@cached_agents)}
              />

              <%!-- Queue drawer overlay --%>
              <.live_component
                :if={@queue_drawer}
                module={LoomkinWeb.MessageQueueComponent}
                id={"queue-drawer-#{@queue_drawer.agent}"}
                queue={Map.get(@agent_queues, @queue_drawer.agent, [])}
                agent_name={@queue_drawer.agent}
                team_id={@queue_drawer.team_id}
              />
            </div>
          </div>

          <%!-- Right: Agent Deep-Focus Panel (w-80, collapsible) --%>
          <.live_component
            module={LoomkinWeb.ContextInspectorComponent}
            id="context-inspector"
            focused_agent={@focused_agent}
            focused_card={if(@focused_agent, do: Map.get(@agent_cards, @focused_agent))}
            inspector_mode={@inspector_mode}
            session_id={@session_id}
            team_id={@active_team_id}
          />
        <% end %>
      </div>

      <%!-- Kin Management Panel --%>
      <.live_component
        :if={@kin_panel_open}
        module={LoomkinWeb.KinPanelComponent}
        id="kin-panel"
        active_team_id={@active_team_id}
        active_agents={@cached_agents}
      />

      <%!-- File Explorer Drawer --%>
      <.live_component
        module={LoomkinWeb.FileExplorerDrawerComponent}
        id="file-explorer-drawer"
        open={@file_drawer_open}
        project_path={@explorer_path}
        file_tree_version={@file_tree_version}
        selected_file={@selected_file}
        file_content={@file_content}
        diffs={@diffs}
      />

      <%!-- Debug signal log overlay --%>
      <div
        :if={@debug_panel_open}
        id="debug-signal-overlay"
        class="fixed bottom-0 left-0 right-0 z-[100] max-h-[40vh] overflow-y-auto bg-zinc-950/95 border-t border-zinc-700 backdrop-blur-sm font-mono text-[11px]"
      >
        <div class="sticky top-0 flex items-center justify-between px-3 py-1.5 bg-zinc-900/90 border-b border-zinc-800">
          <span class="text-zinc-400 font-semibold uppercase tracking-wider text-[10px]">
            Signal Log
          </span>
          <button phx-click="toggle_debug_panel" class="text-zinc-500 hover:text-zinc-300 text-xs">
            Close
          </button>
        </div>
        <div class="px-3 py-1">
          <div
            :for={sig <- @debug_signals}
            class="flex items-center gap-3 py-0.5 border-b border-zinc-800/50"
          >
            <span class="text-zinc-600 tabular-nums flex-shrink-0">{format_debug_ts(sig.at)}</span>
            <span class={debug_signal_color(sig.type)}>{sig.type}</span>
            <span class="text-zinc-500 truncate">{sig.agent}</span>
          </div>
          <div :if={@debug_signals == []} class="py-4 text-center text-zinc-600">
            No signals captured yet
          </div>
        </div>
      </div>
    </div>
    """
  end

  # render_mode/2 removed — inlined in render/1 with .live_component calls
  # card_grid_cols/1, any_agents_active?/2, render_ghost_cards/1, kin_potency_color/1
  # render_budget_bar/1 moved to their respective extracted components

  # render_last_message_strip/1, render_input_bar/1, format_decimal_cost/1 moved to ComposerComponent

  # budget_pct/1 and budget_bar_color/1 stay here — used by refresh_roster/1 to compute assigns
  defp budget_pct(%{spent: spent, limit: limit}) when limit > 0,
    do: round(spent / limit * 100)

  defp budget_pct(_), do: 0

  defp budget_bar_color(%{spent: spent, limit: limit}) when limit > 0 do
    pct = spent / limit * 100

    cond do
      pct >= 90 -> "bg-red-500"
      pct >= 70 -> "bg-amber-500"
      true -> "bg-emerald-500"
    end
  end

  defp budget_bar_color(_), do: "bg-emerald-500"

  # --- Helpers ---

  # Convert persisted session messages into activity feed events.
  # Used on mount to recover feed state after reconnections.
  defp messages_to_activity_events(messages) do
    messages
    |> Enum.filter(fn msg ->
      role = Map.get(msg, :role)
      role in [:user, :assistant]
    end)
    |> Enum.map(fn msg ->
      {agent, from, to} =
        case msg.role do
          :user -> {"You", "You", "Kin"}
          :assistant -> {"concierge", "concierge", "You"}
        end

      %{
        id: "history-#{Ecto.UUID.generate()}",
        type: :message,
        agent: agent,
        content: Map.get(msg, :content) || "",
        timestamp: Map.get(msg, :inserted_at, DateTime.utc_now()),
        expanded: false,
        metadata: %{from: from, to: to}
      }
    end)
  end

  defp status_label(:idle, _tool), do: "Ready"
  defp status_label(:thinking, _tool), do: "Thinking..."
  defp status_label(:streaming, _tool), do: "Streaming..."
  defp status_label(:executing_tool, nil), do: "Running tool..."
  defp status_label(:executing_tool, tool_name), do: tool_name
  defp status_label(:unknown, _tool), do: "Unknown"
  defp status_label(status, _tool), do: to_string(status)

  defp status_banner_class(:idle),
    do: "px-3 py-1 rounded-full text-sm font-semibold bg-zinc-700/80 text-zinc-300"

  defp status_banner_class(:thinking),
    do:
      "px-3 py-1 rounded-full text-sm font-bold bg-amber-500/20 text-amber-200 ring-2 ring-amber-500/50 animate-pulse"

  defp status_banner_class(:streaming),
    do:
      "px-3 py-1 rounded-full text-sm font-bold bg-emerald-500/20 text-emerald-200 ring-2 ring-emerald-500/50 animate-pulse"

  defp status_banner_class(:executing_tool),
    do:
      "px-3 py-1 rounded-full text-sm font-bold bg-blue-500/20 text-blue-200 ring-2 ring-blue-500/50 animate-pulse"

  defp status_banner_class(:error),
    do:
      "px-3 py-1 rounded-full text-sm font-bold bg-red-500/20 text-red-200 ring-2 ring-red-500/50"

  defp status_banner_class(:unknown),
    do:
      "px-3 py-1 rounded-full text-sm font-bold bg-red-500/20 text-red-200 ring-2 ring-red-500/50"

  defp status_banner_class(_),
    do: "px-3 py-1 rounded-full text-sm font-semibold bg-zinc-700/80 text-zinc-300"

  defp append_debug_signal(socket, sig) do
    entry = %{
      type: sig.type,
      at: System.system_time(:millisecond),
      agent: get_in(sig.data, [:agent_name]) || "session"
    }

    assign(socket, :debug_signals, Enum.take([entry | socket.assigns.debug_signals], 50))
  end

  defp forward_raw_event(socket, nil), do: socket

  defp forward_raw_event(socket, raw_event) do
    case handle_info(raw_event, socket) do
      {:noreply, socket} -> socket
      _ -> socket
    end
  end

  # tab_icon/1, tab_label/1, render_tab/2 moved to SidebarPanelComponent

  defp route_permission_response(_socket, action, %{source: {:agent, team_id, agent_name}} = req) do
    case Loomkin.Teams.Manager.find_agent(team_id, agent_name) do
      {:ok, pid} ->
        Loomkin.Teams.Agent.permission_response(pid, action, req.tool_name, req.tool_path)

      :error ->
        :ok
    end

    log_permission_decision(req, action)
  end

  defp route_permission_response(socket, action, req) do
    Session.permission_response(socket.assigns.session_id, action, req.tool_name, req.tool_path)
    log_permission_decision(req, action)
  end

  defp log_permission_decision(req, action) do
    Loomkin.Permissions.Manager.record_decision(%{
      session_id: req.session_id,
      team_id: req.team_id,
      agent_name: req.agent_name,
      tool_name: req.tool_name,
      tool_path: req.tool_path,
      action: action,
      comment: req[:comment]
    })
  end

  defp pop_permission_request(pending, request_id) do
    case Enum.split_with(pending, &(&1.id == request_id)) do
      {[request], remaining} -> {request, remaining}
      {[], remaining} -> {nil, remaining}
    end
  end

  defp pop_permission_request_by_tool(pending, tool_name, tool_path) do
    case Enum.split_with(pending, &(&1.tool_name == tool_name and &1.tool_path == tool_path)) do
      {[request | rest], remaining} -> {request, rest ++ remaining}
      {[], remaining} -> {nil, remaining}
    end
  end

  defp split_permissions_by_scope(pending, "all_reads") do
    Enum.split_with(pending, &(&1.category == :read))
  end

  defp split_permissions_by_scope(pending, "agent:" <> agent_name) do
    Enum.split_with(pending, &(&1.agent_name == agent_name))
  end

  defp split_permissions_by_scope(pending, "all") do
    {pending, []}
  end

  defp split_permissions_by_scope(pending, _unknown) do
    {[], pending}
  end

  defp enqueue_or_auto_respond(socket, agent_name, role, tool_name, tool_path, source, team_id) do
    session_id = socket.assigns.session_id

    request = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      tool_name: tool_name,
      tool_path: tool_path,
      source: source,
      agent_name: agent_name,
      team_id: team_id,
      category: Loomkin.Permissions.Manager.tool_category(tool_name),
      requested_at: DateTime.utc_now()
    }

    case Loomkin.Permissions.TrustPolicy.check(session_id, agent_name, role, tool_name, tool_path) do
      :auto_approve ->
        route_permission_response(socket, "allow_once", request)
        socket

      :deny ->
        route_permission_response(socket, "deny", request)
        socket

      _ask_or_nil ->
        pending = [request | socket.assigns.pending_permissions]
        assign(socket, pending_permissions: pending)
    end
  end

  # Subscribe to a team's PubSub topics, but only once per team.
  # Also synthesizes "joined" events for agents that already exist (race condition fix).
  # Returns the updated socket with the team tracked in :subscribed_teams.
  # Team-based signal filtering is now handled by TeamBroadcaster.
  # signal_for_workspace?/2 and subscribe_global_signals/1 have been removed —
  # the broadcaster pre-filters by team_id and subscribes to global bus paths.

  defp subscribe_to_team(socket, team_id) do
    subscribed = socket.assigns[:subscribed_teams] || MapSet.new()

    if MapSet.member?(subscribed, team_id) do
      socket
    else
      require Logger
      Logger.info("[Kin:UI] subscribing to team=#{team_id}")

      # Subscribe to Phoenix PubSub for session events (MessageScheduler, etc.)
      Phoenix.PubSub.subscribe(Loomkin.PubSub, Topics.team_pubsub(team_id))

      # Register team with TeamBroadcaster for signal filtering
      if broadcaster = socket.assigns[:broadcaster] do
        TeamBroadcaster.add_team(broadcaster, team_id)
      end

      socket = assign(socket, subscribed_teams: MapSet.put(subscribed, team_id))

      # Replay recent decision signals to catch up on events missed before subscription.
      # The bus delivers replayed signals as regular messages, triggering refresh_decision_graphs.
      five_min_ago = System.os_time(:microsecond) - 5 * 60 * 1_000_000
      Loomkin.Signals.replay("decision.**", five_min_ago)

      # Synthesize "joined" events for agents that were spawned before we subscribed
      existing_agents =
        case Loomkin.Teams.Manager.list_agents(team_id) do
          agents when is_list(agents) -> agents
          {:ok, agents} when is_list(agents) -> agents
          _ -> []
        end

      known = socket.assigns.activity_known_agents

      Enum.reduce(existing_agents, socket, fn agent, sock ->
        if agent.name in known do
          sock
        else
          event = %{
            id: Ecto.UUID.generate(),
            type: :agent_spawn,
            agent: agent.name,
            content: "#{agent.name} joined",
            timestamp: DateTime.utc_now(),
            expanded: false,
            metadata: %{agent_name: agent.name, role: agent.role, team_id: team_id}
          }

          new_known = [agent.name | sock.assigns.activity_known_agents]

          sock
          |> push_activity_event(event)
          |> assign(activity_known_agents: new_known)
        end
      end)
    end
  end

  defp send_update_to_model_selector(socket) do
    # Bump auth_version so the component knows to reload providers,
    # even when the model string hasn't changed
    auth_version = (socket.assigns[:auth_version] || 0) + 1

    send_update(LoomkinWeb.ModelSelectorComponent,
      id: "thinking-model-selector",
      model: socket.assigns.model,
      auth_version: auth_version
    )

    send_update(LoomkinWeb.ModelSelectorComponent,
      id: "fast-model-selector",
      model: socket.assigns[:fast_model] || socket.assigns.model,
      auth_version: auth_version
    )

    assign(socket, auth_version: auth_version)
  end

  # Recompute cached roster data.
  # Called on roster refresh — avoids per-render Registry queries.
  # NOTE: Do NOT subscribe to PubSub topics here — this is called from many
  # event handlers and PubSub.subscribe is not idempotent (each call adds
  # another subscription, causing duplicate event delivery).
  defp refresh_decision_graphs(socket) do
    # "inspector-agent-graph" is always mounted in the context inspector (mission control).
    # "decision-graph" lives in the sidebar graph tab (solo mode).
    # "team-decision-graph" lives in the team sub-tab (solo mode, :team tab, :graph sub-tab).
    ref = System.unique_integer()

    if socket.assigns[:mode] == :mission_control do
      send_update(LoomkinWeb.DecisionGraphComponent,
        id: "inspector-agent-graph",
        session_id: socket.assigns[:session_id],
        team_id: socket.assigns[:active_team_id],
        refresh_ref: ref
      )
    end

    send_update(LoomkinWeb.DecisionGraphComponent,
      id: "decision-graph",
      session_id: socket.assigns[:session_id],
      team_id: socket.assigns[:active_team_id],
      refresh_ref: ref
    )

    send_update(LoomkinWeb.DecisionGraphComponent,
      id: "team-decision-graph",
      session_id: socket.assigns[:session_id],
      team_id: socket.assigns[:display_team_id],
      refresh_ref: ref
    )
  end

  defp refresh_task_graph(socket) do
    ref = System.unique_integer()

    send_update(LoomkinWeb.TaskGraphComponent,
      id: "task-graph",
      session_id: socket.assigns[:session_id],
      team_id: socket.assigns[:active_team_id],
      refresh_ref: ref
    )

    socket
  end

  @collab_health_interval_ms 10_000

  defp schedule_collab_health_refresh(socket) do
    if timer = socket.assigns[:collab_health_timer] do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :refresh_collab_health, @collab_health_interval_ms)
    assign(socket, collab_health_timer: timer)
  end

  defp schedule_roster_refresh(socket) do
    require Logger
    Logger.debug("[Kin:UI] roster refresh scheduled (debounced #{@roster_debounce_ms}ms)")

    if timer = socket.assigns[:roster_refresh_timer] do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :debounced_roster_refresh, @roster_debounce_ms)
    assign(socket, roster_refresh_timer: timer)
  end

  defp refresh_roster(socket) do
    require Logger
    team_id = socket.assigns[:active_team_id]
    agents = roster_agents(team_id)
    tasks = roster_tasks(team_id)
    budget = roster_budget(team_id)

    agent_names = Enum.map(agents, & &1.name)

    Logger.info(
      "[Kin:UI] refresh_roster team=#{team_id} agents=#{inspect(agent_names)} count=#{length(agents)}"
    )

    # Subscribe to any sub-teams discovered during roster refresh so their
    # signals are routed through TeamBroadcaster
    sub_team_ids = if team_id, do: Loomkin.Teams.Manager.list_sub_teams(team_id), else: []

    socket =
      Enum.reduce(sub_team_ids, socket, fn sub_id, acc ->
        subscribe_to_team(acc, sub_id)
      end)

    assign(socket,
      cached_agents: agents,
      cached_tasks: tasks,
      cached_budget: budget,
      budget_pct: budget_pct(budget),
      budget_bar_color_class: budget_bar_color(budget)
    )
  end

  defp forward_to_activity(socket, pubsub_event) do
    case activity_event_from(pubsub_event) do
      nil ->
        socket

      :merge_tool_result ->
        merge_tool_result(socket, pubsub_event)

      :maybe_agent_spawn ->
        # Only show "joined" for agents we haven't seen before
        {:agent_status, agent, :idle} = pubsub_event
        known = socket.assigns.activity_known_agents

        if agent in known do
          socket
        else
          event = %{
            id: Ecto.UUID.generate(),
            type: :agent_spawn,
            agent: agent,
            content: "#{agent} joined",
            timestamp: DateTime.utc_now(),
            expanded: false,
            metadata: %{agent_name: agent}
          }

          socket
          |> push_activity_event(event)
          |> assign(activity_known_agents: [agent | known])
        end

      event ->
        agents = socket.assigns.activity_known_agents

        agents =
          case trackable_agent_name(event.agent) do
            nil -> agents
            name -> if name in agents, do: agents, else: [name | agents]
          end

        # Track pending tool events for stream-based merging
        socket =
          if event.type == :tool_call && is_nil((event.metadata || %{})[:result]) do
            key = {event.agent, (event.metadata || %{})[:tool_name]}
            update(socket, :pending_tool_events, &Map.put(&1, key, event))
          else
            socket
          end

        socket
        |> push_activity_event(event)
        |> assign(activity_known_agents: agents)
    end
  end

  # Append a pre-formed activity event (bypasses activity_event_from pattern matching)
  defp append_activity_event(socket, event) do
    agents = socket.assigns.activity_known_agents

    agents =
      case trackable_agent_name(event.agent) do
        nil -> agents
        name -> if name in agents, do: agents, else: [name | agents]
      end

    socket
    |> push_activity_event(event)
    |> assign(activity_known_agents: agents)
  end

  # Send an activity event to the TeamActivityComponent's internal stream
  defp push_activity_event(socket, event) do
    send_update(LoomkinWeb.TeamActivityComponent,
      id: "team-activity",
      new_event: event
    )

    socket
    |> update(:activity_event_count, &(&1 + 1))
    |> update(:buffered_activity_events, &[event | Enum.take(&1, 199)])
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
    key = {agent, "team_assign"}
    pending = socket.assigns.pending_tool_events

    case Map.get(pending, key) do
      nil ->
        event = %{
          id: Ecto.UUID.generate(),
          type: :task_assigned,
          agent: agent,
          content: "Assigned task to #{task_meta[:owner] || "agent"}",
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: task_meta
        }

        socket
        |> push_activity_event(event)

      ev ->
        updated = %{
          ev
          | type: :task_assigned,
            content: "Assigned task to #{task_meta[:owner] || "agent"}",
            metadata: task_meta
        }

        socket
        |> push_activity_event(updated)
        |> update(:pending_tool_events, &Map.delete(&1, key))
    end
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

    key = {agent, tool_name}
    pending = socket.assigns.pending_tool_events

    case Map.get(pending, key) do
      nil ->
        event = %{
          id: Ecto.UUID.generate(),
          type: :tool_call,
          agent: agent,
          content: tool_name || "tool result",
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: %{tool_name: tool_name, result: truncated}
        }

        socket
        |> push_activity_event(event)

      ev ->
        metadata = Map.put(ev.metadata || %{}, :result, truncated)
        updated = %{ev | metadata: metadata, expanded: false}

        socket
        |> push_activity_event(updated)
        |> update(:pending_tool_events, &Map.delete(&1, key))
    end
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
        command: if(name == "shell", do: to_string(payload[:command] || ""), else: nil),
        result: nil
      }
    }
  end

  # tool_complete is handled specially — not via activity_event_from, see forward_to_activity
  defp activity_event_from({:tool_complete, _agent, _payload}), do: :merge_tool_result

  # --- Agent status: surface spawn and working transitions ---

  defp activity_event_from({:agent_status, _agent, :idle}) do
    # Idle status is handled specially in forward_to_activity —
    # only show "joined" for agents we haven't seen before.
    :maybe_agent_spawn
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

  defp activity_event_from({:task_assigned_enriched, _task_id, agent, reasoning}) do
    content =
      case reasoning do
        %{reason: reason} when is_binary(reason) and byte_size(reason) > 0 ->
          "Assigned: #{reason}"

        %{task_title: title} when is_binary(title) ->
          "Picked up: #{title}"

        _ ->
          "Picked up a task"
      end

    %{
      id: Ecto.UUID.generate(),
      type: :task_assigned,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: reasoning
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

  # Task start is redundant with task_assigned — skip to reduce noise
  defp activity_event_from({:task_started, _task_id, _agent}), do: nil

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

  defp activity_event_from({:node_added, data}) when is_map(data) do
    node = data[:node]
    agent = if node, do: node.agent_name || "system", else: "system"
    title = if node, do: node.title, else: "node"
    node_type = if node, do: node.node_type, else: :unknown

    %{
      id: Ecto.UUID.generate(),
      type: :decision,
      agent: agent,
      content: "Added #{node_type}: #{title}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:node_added, _}), do: nil

  defp activity_event_from({:pivot_created, data}) when is_map(data) do
    result = data[:result]

    agent =
      if result, do: (result.decision && result.decision.agent_name) || "system", else: "system"

    old_title = if result && result.old_node, do: result.old_node.title, else: "approach"
    new_title = if result && result.decision, do: result.decision.title, else: "new approach"

    %{
      id: Ecto.UUID.generate(),
      type: :decision,
      agent: agent,
      content: "Pivoted from #{old_title} to #{new_title}",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }
  end

  defp activity_event_from({:pivot_created, _}), do: nil

  defp activity_event_from({:context_update, agent, payload}) do
    content =
      case payload do
        %{type: :discovery, content: c} when is_binary(c) -> c
        %{content: c} when is_binary(c) -> c
        _ -> "Shared a discovery"
      end

    # Extract nested payload for relevance (signal data wraps original payload)
    inner = payload[:payload] || payload
    relevance = payload[:relevance]

    metadata =
      %{discovery_type: to_string(inner[:type] || "discovery")}
      |> then(fn m -> if relevance, do: Map.put(m, :relevance, relevance), else: m end)

    %{
      id: Ecto.UUID.generate(),
      type: :discovery,
      agent: agent,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: metadata
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

  defp activity_event_from({:collab_event, %{type: :conflict_detected} = payload}) do
    agent =
      case payload.agents do
        [first | _] -> first
        _ -> "system"
      end

    meta = payload.metadata || %{}

    %{
      id: Ecto.UUID.generate(),
      type: :conflict,
      agent: agent,
      content: payload.description,
      timestamp: payload.timestamp,
      expanded: false,
      metadata: %{
        collab_type: :conflict_detected,
        conflict_type: meta[:conflict_type],
        agent_a: meta[:agent_a],
        agent_b: meta[:agent_b],
        files: meta[:files] || []
      }
    }
  end

  defp activity_event_from({:collab_event, payload}) do
    # Map collab event type to an activity event type for styling
    event_type =
      case payload.type do
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

  # --- Agent Cards + Comms routing (mission control v2) ---

  # Event types that belong in the inter-agent comms feed
  @comms_event_types [
    :message,
    :discovery,
    :decision,
    :agent_spawn,
    :question,
    :answer,
    :tasks_unblocked,
    :role_changed,
    :escalation,
    :channel_message,
    :peer_message,
    :task_created,
    :task_assigned,
    :task_complete,
    :error,
    :rebalance_nudge,
    :rebalance_escalation,
    :conflict,
    :vote_response,
    :debate_response,
    :healing_started,
    :healing_diagnosis,
    :healing_fix_applied,
    :healing_complete,
    :healing_failed
  ]

  defp forward_to_cards_and_comms(socket, pubsub_event) do
    case activity_event_from(pubsub_event) do
      nil -> socket
      :merge_tool_result -> update_card_tool_result(socket, pubsub_event)
      :maybe_agent_spawn -> maybe_spawn_card(socket, pubsub_event)
      event -> route_event_to_cards_or_comms(socket, event)
    end
  end

  defp route_event_to_cards_or_comms(socket, event) do
    socket =
      if event.type in @comms_event_types do
        socket
        |> stream_insert(:comms_events, event)
        |> update(:comms_event_count, &(&1 + 1))
      else
        socket
      end

    # Tool calls update only the last_tool footer — never overwrite message/thinking content
    # Conflict events set the conflict flag on both agents' cards
    case event.type do
      :tool_call ->
        update_agent_card(socket, event.agent, %{
          last_tool: %{
            name: (event.metadata || %{})[:tool_name] || "tool",
            target: (event.metadata || %{})[:file_path]
          }
        })

      :conflict ->
        meta = event.metadata || %{}
        conflict_info_a = %{with: meta[:agent_b], type: meta[:conflict_type]}
        conflict_info_b = %{with: meta[:agent_a], type: meta[:conflict_type]}

        socket
        |> update_agent_card(to_string(meta[:agent_a] || event.agent), %{
          conflict: conflict_info_a
        })
        |> update_agent_card(to_string(meta[:agent_b] || ""), %{conflict: conflict_info_b})

      _ ->
        socket
    end
  end

  defp maybe_spawn_card(socket, {:agent_status, agent, :idle}) do
    cards = socket.assigns.agent_cards

    if Map.has_key?(cards, agent) do
      socket
    else
      card = default_agent_card(agent, socket)

      comms_event = %{
        id: Ecto.UUID.generate(),
        type: :agent_spawn,
        agent: agent,
        content: "#{agent} joined",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{team_id: card.team_id}
      }

      socket
      |> assign(agent_cards: Map.put(cards, agent, card))
      |> stream_insert(:comms_events, comms_event)
      |> update(:comms_event_count, &(&1 + 1))
      |> update_card_ordering()
    end
  end

  defp update_card_tool_result(socket, {:tool_complete, agent, %{result: result} = payload}) do
    result_str = String.slice(to_string(result), 0, 200)
    tool_name = payload[:tool_name]

    update_agent_card(socket, agent, %{
      last_tool: %{name: tool_name || "tool", target: nil, result: result_str}
    })
  end

  defp update_card_tool_result(socket, _), do: socket

  defp update_agent_card(socket, agent_name, updates) when is_binary(agent_name) do
    cards = socket.assigns.agent_cards
    card = Map.get(cards, agent_name, default_agent_card(agent_name, socket))
    card = Map.merge(card, updates)
    assign(socket, agent_cards: Map.put(cards, agent_name, card))
  end

  defp update_agent_card(socket, _, _), do: socket

  defp update_card_budget(socket, agent_name, payload) do
    cards = socket.assigns.agent_cards

    case Map.get(cards, agent_name) do
      nil ->
        socket

      card ->
        total = (payload[:input_tokens] || 0) + (payload[:output_tokens] || 0)
        updated = Map.update(card, :budget_used, total, &(&1 + total))
        assign(socket, agent_cards: Map.put(cards, agent_name, updated))
    end
  end

  defp update_card_status(socket, agent_name, status, metadata \\ %{}) do
    # Clear stale :last_thinking content when agent goes idle or complete
    extra =
      if status in [:idle, :complete] do
        card = get_in(socket.assigns, [:agent_cards, agent_name])

        if card && card.content_type == :last_thinking do
          %{content_type: :idle, latest_content: nil}
        else
          %{}
        end
      else
        %{}
      end

    # Schedule card removal after termination animation
    extra =
      if status == :complete do
        Process.send_after(self(), {:remove_terminated_card, agent_name}, 3_000)
        Map.put(extra, :terminated, true)
      else
        extra
      end

    # Propagate pause_queued and previous_status from signal metadata
    extra =
      if metadata[:previous_status] do
        Map.put(extra, :previous_status, metadata[:previous_status])
      else
        extra
      end

    extra = Map.put(extra, :pause_queued, metadata[:pause_queued] || false)

    # Clear stuck warning and conflict indicator when agent resumes activity
    extra =
      if status in [:working, :idle] do
        Map.merge(extra, %{
          stuck_warning: false,
          stuck_idle_min: nil,
          stuck_nudge_count: nil,
          stuck_max_nudges: nil,
          stuck_escalated: nil,
          conflict: nil
        })
      else
        extra
      end

    update_agent_card(
      socket,
      agent_name,
      Map.merge(%{status: status, updated_at: DateTime.utc_now()}, extra)
    )
  end

  defp enrich_task_assigned({:task_assigned, task_id, agent_name}, task_title, team_id) do
    task_type = Loomkin.Teams.Capabilities.infer_task_type(task_title)
    ranked = Loomkin.Teams.Capabilities.best_agent_for(team_id, task_type)

    chosen = Enum.find(ranked, fn entry -> entry.agent == agent_name end)
    alternatives = Enum.reject(ranked, fn entry -> entry.agent == agent_name end)

    reasoning = %{
      task_title: task_title,
      task_type: task_type,
      chosen_score: if(chosen, do: Float.round(chosen.score, 2), else: nil),
      chosen_stats: if(chosen, do: chosen.stats, else: nil),
      alternatives:
        alternatives
        |> Enum.take(3)
        |> Enum.map(fn entry ->
          %{agent: entry.agent, score: Float.round(entry.score, 2), stats: entry.stats}
        end),
      reason:
        if chosen && chosen.score > 0 do
          total = chosen.stats.successes + chosen.stats.failures

          "Best at #{task_type} (score: #{Float.round(chosen.score, 2)}, #{chosen.stats.successes}/#{total} success)"
        else
          nil
        end
    }

    {:task_assigned_enriched, task_id, agent_name, reasoning}
  end

  defp update_card_task(socket, agent_name, task_desc) do
    update_agent_card(socket, agent_name, %{
      current_task: task_desc
    })
  end

  defp default_agent_card(agent_name, socket) do
    # Try to find role from cached_agents
    role =
      Enum.find_value(socket.assigns.cached_agents, :agent, fn a ->
        if a.name == agent_name, do: a.role
      end)

    team_id =
      Enum.find_value(socket.assigns.cached_agents, socket.assigns[:active_team_id], fn a ->
        if a.name == agent_name, do: a.team_id
      end)

    %{
      name: agent_name,
      role: role,
      team_id: team_id,
      status: :idle,
      current_task: nil,
      latest_content: nil,
      content_type: :idle,
      last_tool: nil,
      last_response: nil,
      pending_questions: [],
      model: nil,
      budget_used: 0,
      budget_limit: 0,
      updated_at: DateTime.utc_now(),
      new: true
    }
  end

  # Sync agent cards with roster data (status, role, task, team_id)
  defp sync_cards_with_roster(socket) do
    require Logger
    agents = socket.assigns.cached_agents
    cards = socket.assigns.agent_cards

    existing_names = Map.keys(cards)
    incoming_names = Enum.map(agents, & &1.name)
    new_names = incoming_names -- existing_names

    if new_names != [] do
      Logger.info("[Kin:UI] sync_cards NEW agents appearing: #{inspect(new_names)}")
    end

    updated_cards =
      Enum.reduce(agents, cards, fn agent, acc ->
        card = Map.get(acc, agent.name, default_agent_card(agent.name, socket))

        card =
          card
          |> Map.put(:status, agent.status)
          |> Map.put(:role, agent.role)
          |> Map.put(:team_id, agent.team_id)
          |> Map.put(:model, Map.get(agent, :model))
          |> Map.put(:current_task, Map.get(agent, :current_task) || card.current_task)

        Map.put(acc, agent.name, card)
      end)

    Logger.debug(
      "[Kin:UI] sync_cards total=#{map_size(updated_cards)} names=#{inspect(Map.keys(updated_cards))}"
    )

    socket
    |> assign(agent_cards: updated_cards)
    |> update_card_ordering()
  end

  defp update_card_ordering(socket) do
    cards = socket.assigns.agent_cards

    {concierge_names, system_names, worker_names} =
      Enum.reduce(cards, {[], [], []}, fn {name, card}, {c, s, w} ->
        cond do
          card.role in [:concierge] -> {[name | c], s, w}
          card.role in [:weaver] -> {c, [name | s], w}
          true -> {c, s, [name | w]}
        end
      end)

    assign(socket,
      concierge_card_names: concierge_names,
      system_card_names: system_names,
      worker_card_names: worker_names
    )
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

  defp maybe_auto_follow(socket, agent_name, _payload) do
    agent = if is_binary(agent_name), do: agent_name, else: nil

    if socket.assigns.mode == :mission_control && socket.assigns.inspector_mode == :auto_follow &&
         agent do
      assign(socket, focused_agent: agent)
    else
      socket
    end
  end

  # --- Roster data helpers ---

  defp find_agent_pid(socket, agent_name, team_id) do
    effective_team_id =
      if team_id do
        team_id
      else
        # Fall back to scanning cached_agents, then the active team
        fallback_team_id = socket.assigns[:team_id]
        agents = socket.assigns.cached_agents

        Enum.find_value(agents, fallback_team_id, fn a ->
          if a.name == agent_name, do: a.team_id
        end)
      end

    Loomkin.Teams.Manager.find_agent(effective_team_id, agent_name)
  end

  defp roster_agents(nil), do: []

  defp roster_agents(team_id) do
    require Logger

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
    sub_team_count = length(sub_teams)

    Logger.info(
      "[Kin:UI] roster_agents team=#{team_id} parent=#{length(parent_agents)} sub_teams=#{sub_team_count} child=#{length(child_agents)} total=#{length(result)}"
    )

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

  defp load_kin_agents do
    Loomkin.Kin.list_all()
  end

  defp load_recent_projects(current_path) do
    Loomkin.Session.Persistence.list_projects()
    |> Enum.map(& &1.project_path)
    |> Enum.reject(&(&1 == current_path))
    |> Enum.take(5)
  end

  defp forward_to_team_components(socket) do
    forward_to_dashboard(socket)
  end

  defp forward_to_dashboard(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]

    if tid do
      send_update(LoomkinWeb.TeamDashboardComponent, id: "team-dashboard", team_id: tid)
    end
  end

  defp forward_to_cost(socket) do
    tid = socket.assigns[:active_team_id] || socket.assigns[:team_id]

    if tid do
      try do
        send_update(LoomkinWeb.TeamCostComponent, id: "team-cost", team_id: tid)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp trackable_agent_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed in ["", "You", "system"] do
      nil
    else
      trimmed
    end
  end

  defp trackable_agent_name(_), do: nil

  # agent_picker_dot_class/1, agent_color/1 moved to ComposerComponent

  # Accepts a list of agent structs (cached_agents) — groups by team_id for per-team counts
  defp compute_agent_counts(agents) when is_list(agents) do
    Enum.group_by(agents, & &1.team_id)
    |> Map.new(fn {team_id, team_agents} -> {team_id, length(team_agents)} end)
  end

  defp compute_agent_counts(_), do: %{}

  # format_agent_role/1 moved to MissionControlPanelComponent

  defp do_switch_project(socket, path) do
    team_id = socket.assigns[:team_id]

    if team_id do
      # Cancel any in-flight agent loops before switching so they don't
      # operate on the old project between the path update and their next
      # tool call. The :confirm path already cancels, but the direct path
      # (no active agents) may still have loops starting up.
      Teams.Manager.cancel_all_loops(team_id)
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

  defp session_page_title(session_id) do
    case Loomkin.Session.Persistence.get_session(session_id) do
      %{title: title} when is_binary(title) and title != "" ->
        if Regex.match?(~r/^Session \d{4}-\d{2}-\d{2}/, title) do
          "Loomkin - #{String.slice(session_id, 0, 8)}"
        else
          String.slice(title, 0, 60)
        end

      _ ->
        "Loomkin - #{String.slice(session_id, 0, 8)}"
    end
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

  # language_from_path/1 moved to SidebarPanelComponent

  # --- Ask User helpers ---

  defp send_ask_user_answer(question_id, answer) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}) do
      [{pid, _}] ->
        send(pid, {:ask_user_answer, question_id, answer})

      [] ->
        :ok
    end
  end

  defp send_approval_response(gate_id, decision) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}) do
      [{pid, _}] ->
        send(pid, {:approval_response, gate_id, decision})

      [] ->
        :ok
    end
  end

  defp send_spawn_gate_response(gate_id, decision) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id}) do
      [{pid, _}] ->
        send(pid, {:spawn_gate_response, gate_id, decision})

      [] ->
        :ok
    end
  end

  defp handle_collective_decision(socket, question) do
    team_id = question.team_id
    question_id = question.question_id
    options = question.options
    options_text = Enum.join(options, ", ")

    collective_prompt =
      "The human deferred this question to the collective. " <>
        "Question from #{question.agent_name}: #{question.question} " <>
        "Options: #{options_text}. " <>
        "Reply with ONLY your preferred option (exact text)."

    vote_topic = "ask_user:vote:#{question_id}"

    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(
        %{from: "system", team_id: team_id},
        subject: "vote:#{question_id}"
      )

    Loomkin.Signals.publish(%{
      signal
      | data:
          Map.merge(signal.data, %{
            message:
              {:peer_message, "system", collective_prompt,
               %{reply_topic: vote_topic, question_id: question_id, options: options}}
          })
    })

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
    end)

    socket
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

  # Command palette render + helpers moved to CommandPaletteComponent

  defp load_channel_bindings(nil), do: []

  defp load_channel_bindings(team_id) do
    try do
      Loomkin.Channels.Bindings.list_bindings_for_team(team_id)
    rescue
      _e ->
        []
    end
  end

  # agent_is_working?/2 moved to ComposerComponent

  # --- Team tree helpers ---

  # Collect all descendants of team_id from the tree map (recursive)
  defp collect_descendants(tree, team_id) do
    children = Map.get(tree, team_id, [])
    Enum.flat_map(children, fn child -> [child | collect_descendants(tree, child)] end)
  end

  # Remove dissolved_id from tree: delete its key and remove from all parent lists
  defp remove_from_tree(tree, dissolved_id) do
    tree
    |> Map.delete(dissolved_id)
    |> Map.new(fn {parent, children} -> {parent, List.delete(children, dissolved_id)} end)
  end

  # --- Synthesis comms event helpers ---

  defp maybe_insert_synthesis_comms_event(socket, agent_name, :awaiting_synthesis, _metadata) do
    event = %{
      id: Ecto.UUID.generate(),
      type: :awaiting_synthesis_started,
      agent: agent_name,
      content: "#{agent_name} entered awaiting synthesis — collecting research findings",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }

    socket
    |> stream_insert(:comms_events, event)
    |> update(:comms_event_count, &(&1 + 1))
  end

  defp maybe_insert_synthesis_comms_event(
         socket,
         agent_name,
         :working,
         %{previous_status: :awaiting_synthesis}
       ) do
    event = %{
      id: Ecto.UUID.generate(),
      type: :awaiting_synthesis_complete,
      agent: agent_name,
      content: "#{agent_name} synthesis complete — returning to work",
      timestamp: DateTime.utc_now(),
      expanded: false,
      metadata: %{}
    }

    socket
    |> stream_insert(:comms_events, event)
    |> update(:comms_event_count, &(&1 + 1))
  end

  defp maybe_insert_synthesis_comms_event(socket, _agent_name, _status, _metadata), do: socket

  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)

    if seconds < 60 do
      "#{seconds}s"
    else
      "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    end
  end

  defp format_duration(_), do: "unknown"

  defp format_debug_ts(ms) when is_integer(ms) do
    dt = DateTime.from_unix!(ms, :millisecond)
    Calendar.strftime(dt, "%H:%M:%S.") <> String.pad_leading(to_string(rem(ms, 1000)), 3, "0")
  end

  defp format_debug_ts(_), do: "--:--:--"

  defp debug_signal_color(type) when is_binary(type) do
    cond do
      String.contains?(type, "error") or String.contains?(type, "crash") ->
        "text-red-400"

      String.contains?(type, "approval") or String.contains?(type, "permission") ->
        "text-violet-400"

      String.contains?(type, "ask_user") ->
        "text-amber-400"

      String.contains?(type, "spawn") ->
        "text-cyan-400"

      String.contains?(type, "status") ->
        "text-green-400"

      String.contains?(type, "stream") ->
        "text-blue-400"

      String.contains?(type, "tool") ->
        "text-pink-400"

      true ->
        "text-zinc-400"
    end
  end

  defp debug_signal_color(_), do: "text-zinc-400"

  # --- UI state restore helpers (used by restore_ui_state event) ---

  defp restore_assign(socket, key, value, valid_values) when is_binary(value) do
    if value in valid_values do
      assign(socket, [{key, String.to_existing_atom(value)}])
    else
      socket
    end
  end

  defp restore_assign(socket, _key, _value, _valid), do: socket

  defp restore_assign_bool(socket, key, value) when is_boolean(value) do
    assign(socket, [{key, value}])
  end

  defp restore_assign_bool(socket, _key, _value), do: socket

  defp restore_assign_string(socket, key, value) when is_binary(value) and value != "" do
    assign(socket, [{key, value}])
  end

  defp restore_assign_string(socket, _key, _value), do: socket
end
