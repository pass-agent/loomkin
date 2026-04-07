defmodule LoomkinWeb.SessionChannel do
  @moduledoc """
  Channel for real-time session message streaming.

  Clients join `session:<session_id>` to receive live updates
  as agents produce messages, tool calls, and status changes.

  Subscribes to the Jido Signal Bus for session and team signals,
  forwarding them as channel events to connected clients (CLI, mobile).
  """

  use Phoenix.Channel

  require Logger

  alias Loomkin.Session
  alias Loomkin.Session.Persistence

  @impl true
  def join("session:" <> session_id, _params, socket) do
    case Persistence.get_session(session_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      session ->
        # Start the Session GenServer (agent loop) if not already running.
        # This is needed for CLI/mobile clients where the REST API only
        # creates a DB record without starting the GenServer.
        ensure_session_started(session)

        # Subscribe to session, team, agent, and collaboration signals so we can forward them
        Session.subscribe(session_id)
        Loomkin.Signals.subscribe("team.**")
        Loomkin.Signals.subscribe("agent.**")
        Loomkin.Signals.subscribe("collaboration.**")

        {:ok, %{model: session.model},
         socket
         |> assign(:session_id, session_id)
         |> assign(:team_id, session.team_id)}
    end
  end

  # --- Client messages ---

  @impl true
  def handle_in("send_message", %{"content" => content} = params, socket) do
    session_id = socket.assigns.session_id
    target_agent = params["target_agent"]

    # Dispatch to the Session GenServer asynchronously.
    # The GenServer saves the user message, broadcasts it via the signal bus,
    # and triggers the AI agent loop. All events (user echo, stream tokens,
    # assistant response) flow back through handle_info signal handlers.
    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      case Session.send_message(session_id, content, target_agent: target_agent) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[SessionChannel] send_message failed session=#{session_id} reason=#{inspect(reason)}"
          )
      end
    end)

    {:reply, :ok, socket}
  end

  def handle_in("permission_response", %{"id" => request_id, "action" => action}, socket) do
    case Loomkin.Channels.PermissionRegistry.resolve_request(request_id, action) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("ask_user_answer", %{"question_id" => question_id, "answer" => answer}, socket) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}) do
      [{pid, _}] ->
        send(pid, {:ask_user_answer, question_id, answer})
        {:reply, :ok, socket}

      [] ->
        {:reply, {:error, %{reason: "question_expired"}}, socket}
    end
  end

  @valid_roles ~w(concierge lead coder researcher reviewer tester weaver)a

  def handle_in("spawn_agent", %{"role" => role} = params, socket) do
    case parse_role(role) do
      {:ok, role_atom} ->
        session_id = socket.assigns.session_id
        session = Persistence.get_session(session_id)
        name = params["name"] || role
        model = params["model"]
        project_path = session && session.project_path

        {:ok, team_id} = ensure_team_id(session, session_id, project_path)

        opts =
          [project_path: project_path, session_id: session_id] ++
            if(model, do: [model: model], else: [])

        case Loomkin.Teams.Manager.spawn_agent(team_id, name, role_atom, opts) do
          {:ok, _pid} ->
            notify_concierge_of_spawn(team_id, name, role)
            {:reply, {:ok, %{name: name, role: role, team_id: team_id}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      {:error, :invalid_role} ->
        valid = @valid_roles |> Enum.map(&to_string/1) |> Enum.join(", ")
        {:reply, {:error, %{reason: "invalid role: #{role}. Valid roles: #{valid}"}}, socket}
    end
  end

  def handle_in("set_model", %{"model" => model}, socket) do
    session_id = socket.assigns.session_id

    case Session.update_model(session_id, model) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("set_fast_model", %{"model" => model}, socket) do
    session_id = socket.assigns.session_id

    case Session.update_fast_model(session_id, model) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("list_kindreds", _params, socket) do
    session = Persistence.get_session(socket.assigns.session_id)

    case fetch_session_user(session) do
      nil ->
        {:reply, {:ok, %{kindreds: []}}, socket}

      user ->
        kindreds =
          Loomkin.Kindred.list_user_kindreds(user)
          |> Enum.map(fn k ->
            item_count = length(Loomkin.Kindred.list_items(k))

            %{
              id: k.id,
              name: k.name,
              version: k.version,
              status: to_string(k.status),
              item_count: item_count
            }
          end)

        active = Loomkin.Kindred.active_kindred_for_user(user)

        {:reply,
         {:ok,
          %{
            kindreds: kindreds,
            active_id: active && active.id
          }}, socket}
    end
  end

  def handle_in("list_kin", _params, socket) do
    kin_agents =
      Loomkin.Kin.list_kin()
      |> Enum.map(fn kin ->
        %{
          id: kin.id,
          name: kin.name,
          role: to_string(kin.role),
          display_name: kin.display_name,
          potency: kin.potency,
          auto_spawn: kin.auto_spawn,
          spawn_context: kin.spawn_context,
          model_override: kin.model_override,
          budget_limit: kin.budget_limit,
          tags: kin.tags || [],
          enabled: kin.enabled
        }
      end)

    {:reply, {:ok, %{kin: kin_agents}}, socket}
  end

  def handle_in("spawn_kin", %{"name" => kin_name}, socket) do
    session_id = socket.assigns.session_id
    session = Persistence.get_session(session_id)

    case Loomkin.Kin.get_kin_by_name(kin_name) do
      nil ->
        {:reply, {:error, %{reason: "kin not found: #{kin_name}"}}, socket}

      kin ->
        project_path = session && session.project_path
        {:ok, team_id} = ensure_team_id(session, session_id, project_path)

        opts =
          [project_path: project_path, session_id: session_id] ++
            if(kin.model_override, do: [model: kin.model_override], else: []) ++
            if(kin.system_prompt_extra,
              do: [system_prompt_extra: kin.system_prompt_extra],
              else: []
            ) ++
            if(kin.budget_limit, do: [budget_limit: kin.budget_limit], else: [])

        case Loomkin.Teams.Manager.spawn_agent(team_id, kin.name, kin.role, opts) do
          {:ok, _pid} ->
            notify_concierge_of_spawn(team_id, kin.name, to_string(kin.role))

            {:reply,
             {:ok,
              %{
                name: kin.name,
                role: to_string(kin.role),
                team_id: team_id,
                display_name: kin.display_name
              }}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end
    end
  end

  def handle_in("list_agents", _params, socket) do
    session = Persistence.get_session(socket.assigns.session_id)

    case session && session.team_id do
      nil ->
        {:reply, {:ok, %{agents: []}}, socket}

      team_id ->
        agents =
          Loomkin.Teams.Context.list_agents(team_id)
          |> Enum.map(fn {name, info} ->
            %{
              name: name,
              role: to_string(info[:role] || "agent"),
              status: to_string(info[:status] || "idle")
            }
          end)

        {:reply, {:ok, %{agents: agents}}, socket}
    end
  end

  # --- Agent lifecycle commands ---

  def handle_in("pause_agent", %{"agent_name" => agent_name}, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        Loomkin.Teams.Agent.request_pause(pid)
        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  def handle_in("force_pause_agent", %{"agent_name" => agent_name}, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.force_pause(pid)
        end)

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  def handle_in("resume_agent", %{"agent_name" => agent_name} = params, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        guidance = params["guidance"]

        opts =
          if guidance && guidance != "",
            do: [guidance: guidance],
            else: []

        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.resume(pid, opts)
        end)

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  def handle_in("steer_agent", %{"agent_name" => agent_name, "guidance" => guidance}, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.steer(pid, guidance)
        end)

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  def handle_in("inject_guidance", %{"agent_name" => agent_name, "text" => text}, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.inject_guidance(pid, text)
        end)

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  def handle_in("cancel_agent", %{"agent_name" => agent_name}, socket) do
    case find_session_agent(socket, agent_name) do
      {:ok, pid} ->
        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          Loomkin.Teams.Agent.cancel(pid)
        end)

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "agent not found: #{agent_name}"}}, socket}
    end
  end

  # --- Gate responses ---

  @valid_gate_outcomes ~w(approved denied)

  def handle_in(
        "approval_response",
        %{"gate_id" => gate_id, "outcome" => outcome} = params,
        socket
      )
      when outcome in @valid_gate_outcomes do
    outcome_atom = String.to_existing_atom(outcome)

    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}) do
      [{pid, _}] ->
        decision = %{
          outcome: outcome_atom,
          context: params["context"],
          reason: params["reason"]
        }

        send(pid, {:approval_response, gate_id, decision})
        {:reply, :ok, socket}

      [] ->
        {:reply, {:error, %{reason: "gate expired or not found"}}, socket}
    end
  end

  def handle_in(
        "spawn_gate_response",
        %{"gate_id" => gate_id, "outcome" => outcome} = params,
        socket
      )
      when outcome in @valid_gate_outcomes do
    outcome_atom = String.to_existing_atom(outcome)

    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id}) do
      [{pid, _}] ->
        decision = %{
          outcome: outcome_atom,
          context: params["context"],
          reason: params["reason"]
        }

        send(pid, {:spawn_gate_response, gate_id, decision})
        {:reply, :ok, socket}

      [] ->
        {:reply, {:error, %{reason: "gate expired or not found"}}, socket}
    end
  end

  # --- Signal forwarding ---

  # Unwrap signal bus delivery tuples
  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, socket), do: handle_info(sig, socket)

  @impl true
  def handle_info(%Jido.Signal{type: "session.message.new"} = sig, socket) do
    if sig.data[:session_id] == socket.assigns.session_id do
      msg = Map.get(sig.data, :message, sig.data)
      push(socket, "new_message", %{message: serialize_signal_message(msg)})
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "session.status.changed"} = sig, socket) do
    if sig.data[:session_id] == socket.assigns.session_id do
      case sig.data[:raw_event] do
        {:stream_start, _sid} ->
          push(socket, "stream_start", %{})

        {:stream_delta, _sid, %{content: content}} when is_binary(content) ->
          push(socket, "stream_token", %{token: content})

        {:stream_delta, _sid, %{tool_call: tool_call}} ->
          push(socket, "tool_call_started", %{tool_call: tool_call})

        {:stream_end, _sid} ->
          push(socket, "stream_end", %{})

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "session.permission.request"} = sig, socket) do
    if sig.data[:session_id] == socket.assigns.session_id do
      # Register in PermissionRegistry so clients can respond by request_id
      request_id =
        case sig.data do
          %{team_id: team_id, agent_name: agent_name, tool_name: tool_name, tool_path: tool_path} ->
            agent_pid =
              case Registry.lookup(Loomkin.Teams.AgentRegistry, {:agent, team_id, agent_name}) do
                [{pid, _}] -> pid
                [] -> nil
              end

            if agent_pid do
              Loomkin.Channels.PermissionRegistry.register_request(
                team_id,
                agent_name,
                tool_name,
                tool_path,
                agent_pid
              )
            end

          _ ->
            nil
        end

      push(socket, "permission_request", %{
        id: request_id,
        tool_name: sig.data[:tool_name],
        tool_path: sig.data[:tool_path],
        agent_name: sig.data[:agent_name],
        category: to_string(sig.data[:category] || "execute")
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "team.ask_user.question"} = sig, socket) do
    push(socket, "ask_user", %{
      question_id: sig.data[:question_id],
      agent_name: sig.data[:agent_name],
      question: sig.data[:question],
      options: sig.data[:options] || []
    })

    {:noreply, socket}
  end

  # --- Agent signal forwarding (filtered by team_id) ---

  def handle_info(%Jido.Signal{type: "agent.status"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_status", %{
        agent_name: sig.data[:agent_name],
        status: to_string(sig.data[:status]),
        previous_status: to_string(sig.data[:previous_status] || ""),
        pause_queued: sig.data[:pause_queued] || false
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.role.changed"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_role_changed", %{
        agent_name: sig.data[:agent_name],
        old_role: to_string(sig.data[:old_role]),
        new_role: to_string(sig.data[:new_role])
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.tool.executing"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_tool_executing", %{
        agent_name: sig.data[:agent_name],
        tool_name: sig.data[:tool_name]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.tool.complete"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_tool_complete", %{
        agent_name: sig.data[:agent_name],
        tool_name: sig.data[:tool_name]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.error"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_error", %{
        agent_name: sig.data[:agent_name],
        error: format_agent_error(sig.data)
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.usage"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "agent_usage", %{
        agent_name: sig.data[:agent_name],
        tokens_used: sig.data[:tokens_used],
        cost_usd: sig.data[:cost_usd]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "team.task." <> _} = sig, socket) do
    push(socket, "team_task_update", %{
      type: sig.type,
      agent_name: sig.data[:agent_name],
      task_id: sig.data[:task_id],
      task: sig.data[:task],
      status: to_string(sig.data[:status] || "")
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "team.spawn.confirmed"} = sig, socket) do
    push(socket, "agent_spawned", %{
      agent_name: sig.data[:agent_name],
      role: to_string(sig.data[:role] || ""),
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "team.dissolved"} = sig, socket) do
    push(socket, "team_dissolved", %{
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  # --- Collaboration signals ---

  def handle_info(%Jido.Signal{type: "collaboration.peer.message"} = sig, socket) do
    {from, content} = serialize_peer_message(sig.data)

    push(socket, "peer_message", %{
      from: from,
      to: sig.data[:target] || sig.data[:to],
      content: content,
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.started"} = sig, socket) do
    push(socket, "conversation_started", %{
      topic: sig.data[:topic],
      participants: sig.data[:participants] || [],
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.ended"} = sig, socket) do
    push(socket, "conversation_ended", %{
      topic: sig.data[:topic],
      outcome: sig.data[:outcome],
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.debate.response"} = sig, socket) do
    push(socket, "debate_response", %{
      from: sig.data[:from] || sig.data[:agent_name],
      position: sig.data[:position],
      reasoning: sig.data[:reasoning],
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.vote.response"} = sig, socket) do
    push(socket, "vote_response", %{
      from: sig.data[:from] || sig.data[:agent_name],
      vote: sig.data[:vote],
      reason: sig.data[:reason],
      team_id: sig.data[:team_id]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "session.llm.error"} = sig, socket) do
    if sig.data[:session_id] == socket.assigns.session_id do
      push(socket, "llm_error", %{error: to_string(sig.data[:error] || "unknown error")})
    end

    {:noreply, socket}
  end

  # --- Team available — update team_id in assigns for agent signal filtering ---

  def handle_info(%Jido.Signal{type: "session.team.available"} = sig, socket) do
    if sig.data[:session_id] == socket.assigns.session_id do
      {:noreply, assign(socket, :team_id, sig.data[:team_id])}
    else
      {:noreply, socket}
    end
  end

  # --- Agent streaming signals — forwarded to CLI/mobile clients ---

  def handle_info(%Jido.Signal{type: "agent.stream.start"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "stream_start", %{})
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.stream.delta"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      token = get_in(sig.data, [:payload, :text]) || ""
      if token != "", do: push(socket, "stream_token", %{token: token})
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.stream.end"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "stream_end", %{})
    end

    {:noreply, socket}
  end

  # --- Conversation turn-level signals (filtered by team_id) ---

  def handle_info(%Jido.Signal{type: "collaboration.conversation.turn"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_turn", %{
        conversation_id: sig.data[:conversation_id],
        speaker: sig.data[:speaker],
        content: sig.data[:content],
        round: sig.data[:round],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.reaction"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_reaction", %{
        conversation_id: sig.data[:conversation_id],
        agent_name: sig.data[:agent_name],
        reaction_type: to_string(sig.data[:reaction_type] || ""),
        brief: sig.data[:brief] || "",
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.yield"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_yield", %{
        conversation_id: sig.data[:conversation_id],
        agent_name: sig.data[:agent_name],
        reason: sig.data[:reason] || "",
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.round_started"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_round_started", %{
        conversation_id: sig.data[:conversation_id],
        round: sig.data[:round],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(
        %Jido.Signal{type: "collaboration.conversation.round_complete"} = sig,
        socket
      ) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_round_complete", %{
        conversation_id: sig.data[:conversation_id],
        round: sig.data[:round],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.summarizing"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_summarizing", %{
        conversation_id: sig.data[:conversation_id],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.budget_warning"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "conversation_budget_warning", %{
        conversation_id: sig.data[:conversation_id],
        tokens_used: sig.data[:tokens_used],
        max_tokens: sig.data[:max_tokens],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  # --- Gate signal forwarding ---

  def handle_info(%Jido.Signal{type: "agent.approval.requested"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "approval_requested", %{
        gate_id: sig.data[:gate_id],
        agent_name: sig.data[:agent_name],
        question: sig.data[:question] || "",
        timeout_ms: sig.data[:timeout_ms] || 300_000,
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.approval.resolved"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "approval_resolved", %{
        gate_id: sig.data[:gate_id],
        agent_name: sig.data[:agent_name],
        outcome: to_string(sig.data[:outcome] || ""),
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.spawn.gate.requested"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "spawn_gate_requested", %{
        gate_id: sig.data[:gate_id],
        agent_name: sig.data[:agent_name],
        team_name: sig.data[:team_name] || "",
        roles: sig.data[:roles] || [],
        estimated_cost: sig.data[:estimated_cost] || 0,
        purpose: sig.data[:purpose],
        timeout_ms: sig.data[:timeout_ms] || 300_000,
        limit_warning: sig.data[:limit_warning],
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.spawn.gate.resolved"} = sig, socket) do
    if sig.data[:team_id] == socket.assigns[:team_id] do
      push(socket, "spawn_gate_resolved", %{
        gate_id: sig.data[:gate_id],
        agent_name: sig.data[:agent_name],
        outcome: to_string(sig.data[:outcome] || ""),
        team_id: sig.data[:team_id]
      })
    end

    {:noreply, socket}
  end

  # Catch-all for unhandled signals
  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  # --- Serialization ---

  defp format_agent_error(data) do
    payload = data[:payload]

    cond do
      present_string?(data[:error]) ->
        to_string(data[:error])

      present_string?(data[:message]) ->
        to_string(data[:message])

      is_map(payload) && is_integer(payload[:max]) ->
        "Exceeded max iterations (#{payload[:max]})"

      is_map(payload) && present_string?(payload[:reason]) ->
        to_string(payload[:reason])

      is_map(payload) && present_string?(payload[:error]) ->
        to_string(payload[:error])

      true ->
        "unknown"
    end
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp ensure_session_started(session) do
    opts =
      [
        session_id: session.id,
        model: session.model,
        fast_model: session.fast_model,
        project_path: session.project_path,
        user_id: session.user_id
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Session.Manager.start_session(opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[SessionChannel] failed to start session: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("[SessionChannel] ensure_session_started error: #{inspect(e)}")
      :error
  end

  defp find_session_agent(socket, agent_name) do
    case socket.assigns[:team_id] do
      nil -> :error
      team_id -> Loomkin.Teams.Manager.find_agent(team_id, agent_name)
    end
  end

  defp ensure_team_id(session, session_id, project_path) do
    case session && session.team_id do
      nil ->
        {:ok, tid} =
          Loomkin.Teams.Manager.create_team(
            name: "cli-team-#{String.slice(session_id, 0..7)}",
            project_path: project_path
          )

        Persistence.update_session(session, %{team_id: tid})
        {:ok, tid}

      tid ->
        {:ok, tid}
    end
  end

  defp parse_role(role) when is_binary(role) do
    atom = String.to_existing_atom(role)
    if atom in @valid_roles, do: {:ok, atom}, else: {:error, :invalid_role}
  rescue
    ArgumentError -> {:error, :invalid_role}
  end

  defp fetch_session_user(nil), do: nil

  defp fetch_session_user(%{user_id: nil}), do: nil

  defp fetch_session_user(%{user_id: user_id}) do
    Loomkin.Accounts.get_user!(user_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp notify_concierge_of_spawn(team_id, agent_name, role) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, "concierge"}) do
      [{pid, _}] ->
        message =
          "The user manually spawned agent \"#{agent_name}\" (role: #{role}) via the CLI. " <>
            "This agent is now available in your team. You may delegate #{role}-related tasks to it."

        Loomkin.Teams.Agent.add_briefing(pid, message)

      [] ->
        :ok
    end
  end

  defp serialize_peer_message(data) do
    fallback_from = data[:from] || data[:agent_name]

    case data[:message] do
      {:peer_message, sender, text} when is_binary(text) ->
        {sender || fallback_from, text}

      text when is_binary(text) ->
        {fallback_from, text}

      nil ->
        {fallback_from, data[:content]}

      other ->
        {fallback_from, inspect(other)}
    end
  end

  defp serialize_signal_message(msg) when is_map(msg) do
    %{
      id: msg[:id] || msg[:message_id] || Ecto.UUID.generate(),
      role: to_string(msg[:role] || "assistant"),
      content: msg[:content],
      tool_calls: msg[:tool_calls],
      tool_call_id: msg[:tool_call_id],
      token_count: msg[:token_count],
      agent_name: msg[:agent_name] || msg[:from],
      inserted_at: msg[:inserted_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
