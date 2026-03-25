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

        # Subscribe to session, team, and agent signals so we can forward them
        Session.subscribe(session_id)
        Loomkin.Signals.subscribe("team.**")
        Loomkin.Signals.subscribe("agent.**")

        {:ok, assign(socket, :session_id, session_id)}
    end
  end

  # --- Client messages ---

  @impl true
  def handle_in("send_message", %{"content" => content}, socket) do
    session_id = socket.assigns.session_id

    # Dispatch to the Session GenServer asynchronously.
    # The GenServer saves the user message, broadcasts it via the signal bus,
    # and triggers the AI agent loop. All events (user echo, stream tokens,
    # assistant response) flow back through handle_info signal handlers.
    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      case Session.send_message(session_id, content) do
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

  def handle_in("spawn_agent", %{"role" => role} = params, socket) do
    session_id = socket.assigns.session_id
    session = Persistence.get_session(session_id)
    name = params["name"] || role
    model = params["model"]
    project_path = session && session.project_path

    # Ensure team exists — create one if the session doesn't have one
    team_id =
      case session && session.team_id do
        nil ->
          {:ok, tid} =
            Loomkin.Teams.Manager.create_team(
              name: "cli-team-#{session_id |> String.slice(0..7)}",
              project_path: project_path
            )

          Persistence.update_session(session, %{team_id: tid})
          tid

        tid ->
          tid
      end

    if team_id do
      opts =
        [project_path: project_path, session_id: session_id] ++
          if(model, do: [model: model], else: [])

      case Loomkin.Teams.Manager.spawn_agent(team_id, name, String.to_atom(role), opts) do
        {:ok, _pid} ->
          {:reply, {:ok, %{name: name, role: role, team_id: team_id}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "failed to create team"}}, socket}
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

  # --- Agent signal forwarding ---

  def handle_info(%Jido.Signal{type: "agent.status"} = sig, socket) do
    push(socket, "agent_status", %{
      agent_name: sig.data[:agent_name],
      status: to_string(sig.data[:status]),
      previous_status: to_string(sig.data[:previous_status] || ""),
      pause_queued: sig.data[:pause_queued] || false
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.role.changed"} = sig, socket) do
    push(socket, "agent_role_changed", %{
      agent_name: sig.data[:agent_name],
      old_role: to_string(sig.data[:old_role]),
      new_role: to_string(sig.data[:new_role])
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.tool.executing"} = sig, socket) do
    push(socket, "agent_tool_executing", %{
      agent_name: sig.data[:agent_name],
      tool_name: sig.data[:tool_name]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.tool.complete"} = sig, socket) do
    push(socket, "agent_tool_complete", %{
      agent_name: sig.data[:agent_name],
      tool_name: sig.data[:tool_name]
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.error"} = sig, socket) do
    push(socket, "agent_error", %{
      agent_name: sig.data[:agent_name],
      error: to_string(sig.data[:error] || sig.data[:message] || "unknown")
    })

    {:noreply, socket}
  end

  def handle_info(%Jido.Signal{type: "agent.usage"} = sig, socket) do
    push(socket, "agent_usage", %{
      agent_name: sig.data[:agent_name],
      tokens_used: sig.data[:tokens_used],
      cost_usd: sig.data[:cost_usd]
    })

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
    push(socket, "peer_message", %{
      from: sig.data[:from] || sig.data[:agent_name],
      to: sig.data[:to],
      content: sig.data[:content],
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

  # Catch-all for unhandled signals
  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  # --- Serialization ---

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

  defp serialize_signal_message(msg) when is_map(msg) do
    %{
      id: msg[:id] || msg[:message_id] || Ecto.UUID.generate(),
      role: to_string(msg[:role] || "assistant"),
      content: msg[:content],
      tool_calls: msg[:tool_calls],
      tool_call_id: msg[:tool_call_id],
      token_count: msg[:token_count],
      agent_name: msg[:agent_name],
      inserted_at: msg[:inserted_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
