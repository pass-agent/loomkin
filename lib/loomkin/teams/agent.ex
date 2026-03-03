defmodule Loomkin.Teams.Agent do
  @moduledoc """
  GenServer representing a single agent within a team. Every Loomkin conversation
  runs through a Teams.Agent — even solo sessions are a team of one.

  Uses Loomkin.AgentLoop for the ReAct cycle, Loomkin.Teams.Role for configuration,
  and communicates with peers via Phoenix.PubSub.
  """

  use GenServer

  alias Loomkin.AgentLoop
  alias Loomkin.Teams.{Comms, Context, ContextRetrieval, CostTracker, Manager, ModelRouter, PriorityRouter, RateLimiter, Role}

  require Logger

  defstruct [
    :team_id,
    :name,
    :role,
    :role_config,
    :status,
    :model,
    :project_path,
    tools: [],
    messages: [],
    task: nil,
    context: %{},
    cost_usd: 0.0,
    tokens_used: 0,
    failure_count: 0,
    permission_mode: :auto,
    pending_permission: nil,
    loop_task: nil,
    pending_updates: [],
    priority_queue: []
  ]

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loomkin.Teams.AgentRegistry, {team_id, name}, %{role: opts[:role], status: :idle}}}
    )
  end

  @doc "Send a user message to this agent and get the response."
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  @doc "Assign a task to this agent."
  def assign_task(pid, task) do
    GenServer.cast(pid, {:assign_task, task})
  end

  @doc "Send a peer message to this agent."
  def peer_message(pid, from, content) do
    GenServer.cast(pid, {:peer_message, from, content})
  end

  @doc "Get current agent status."
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc "Get conversation history."
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  @doc "Cancel an in-progress agent loop."
  def cancel(pid), do: GenServer.call(pid, :cancel)

  @doc """
  Change the role of this agent.

  ## Options
    * `:require_approval` - if true, sends approval request to team lead before changing (default: false)
  """
  def change_role(pid, new_role, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:change_role, new_role, opts}, :infinity)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)
    role = Keyword.fetch!(opts, :role)
    project_path = Keyword.get(opts, :project_path)

    permission_mode = Keyword.get(opts, :permission_mode, :auto)

    case Role.get(role) do
      {:ok, role_config} ->
        model = Keyword.get(opts, :model) || ModelRouter.default_model()

        Comms.subscribe(team_id, name)

        state = %__MODULE__{
          team_id: team_id,
          name: name,
          role: role,
          role_config: role_config,
          status: :idle,
          model: model,
          project_path: project_path,
          tools: role_config.tools,
          permission_mode: permission_mode
        }

        Context.register_agent(team_id, name, %{role: role, status: :idle, model: model})
        broadcast_team(state, {:agent_status, state.name, :idle})

        {:ok, state}

      {:error, :unknown_role} ->
        {:stop, {:unknown_role, role}}
    end
  end

  # --- handle_call ---

  @impl true
  def handle_call({:send_message, _text}, _from, %{loop_task: {_, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call({:send_message, text}, from, state) do
    state = set_status(state, :working)

    user_message = %{role: :user, content: text}
    messages = state.messages ++ [user_message]

    broadcast_team(state, {:agent_status, state.name, :working})

    loop_opts = build_loop_opts(state)
    snapshot = build_snapshot(state)

    task = Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
      run_loop_with_escalation(messages, loop_opts, snapshot)
    end)

    {:noreply, %{state | loop_task: {task, from}}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_call({:change_role, new_role, opts}, _from, state) do
    if opts[:require_approval] do
      # Send approval request to lead and wait synchronously
      request_id = Ecto.UUID.generate()
      Comms.broadcast(state.team_id, {:role_change_request, state.name, state.role, new_role, request_id})

      # For now, pending approval proceeds immediately — the lead can reject via PubSub
      # A full interactive approval flow would require async state, which we avoid here.
      do_change_role(state, new_role)
    else
      do_change_role(state, new_role)
    end
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    case state.loop_task do
      {%Task{} = task, original_from} ->
        Logger.info("[Agent:#{state.name}] Cancelling agent loop")
        Task.shutdown(task, :brutal_kill)
        task_id = state.task && state.task[:id]
        if original_from, do: GenServer.reply(original_from, {:error, :cancelled})
        if !original_from && task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "cancelled")
        state = %{state | loop_task: nil, pending_updates: [], priority_queue: []}
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_task_running}, state}
    end
  end

  # --- handle_cast ---

  @impl true
  def handle_cast({:assign_task, task}, state) do
    Logger.info("[Agent:#{state.name}] Assigned task: #{inspect(task[:id] || task)}")
    # Only override model if the task has an explicit model_hint;
    # otherwise preserve the agent's current model (set at spawn from user's selection)
    model = if task[:model_hint], do: ModelRouter.select(state.role, task), else: state.model
    state = %{state | task: task, model: model}

    messages = maybe_prefetch_context(state, task)

    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_cast({:update_project_path, new_path}, state) do
    Logger.debug("[Agent:#{state.name}] Updated project_path to #{new_path}")
    {:noreply, %{state | project_path: new_path}}
  end

  @impl true
  def handle_cast({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    {:noreply, %{state | messages: state.messages ++ [peer_msg]}}
  end

  @impl true
  def handle_cast({:permission_response, action, tool_name, tool_path}, state) do
    case state.pending_permission do
      nil ->
        {:noreply, state}

      pending_info ->
        if action == "allow_always" do
          # Store grant with the actual resolved path, not wildcard
          Loomkin.Permissions.Manager.grant(to_string(tool_name), tool_path, state.team_id)
        end

        # Resume in a task to avoid blocking the GenServer
        agent_pid = self()
        messages = state.messages
        team_id = state.team_id

        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          tool_result =
            if action in ["allow_once", "allow_always"] do
              pd = pending_info.pending_data
              # Refresh project_path in the tool context before re-executing
              fresh_path = resolve_project_path(team_id, pd.context[:project_path])
              context = Map.put(pd.context, :project_path, fresh_path)
              AgentLoop.default_run_tool(pd.tool_module, pd.tool_args, context)
            else
              "Error: Permission denied for #{tool_name}"
            end

          result = AgentLoop.resume(tool_result, pending_info, messages)
          send(agent_pid, {:loop_resumed, result})
        end)

        {:noreply, %{state | pending_permission: nil}}
    end
  end

  # --- Async loop result handlers ---

  @impl true
  def handle_info({ref, {:loop_ok, text, msgs, meta}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        task_id = state.task && state.task[:id]
        if task_id, do: ModelRouter.record_success(state.team_id, state.name, task_id, state.model)

        state = %{state | messages: msgs, failure_count: 0, loop_task: nil}
        state = track_usage(state, meta)
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})

        if from do
          GenServer.reply(from, {:ok, text})
        else
          if task_id, do: Loomkin.Teams.Tasks.complete_task(task_id, text)
        end

        {:noreply, drain_queues(state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, {:loop_ok_escalated, text, msgs, meta, new_model}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        task_id = state.task && state.task[:id]
        if task_id, do: ModelRouter.record_success(state.team_id, state.name, task_id, new_model)

        state = %{state | messages: msgs, failure_count: 0, model: new_model, loop_task: nil}
        state = track_usage(state, meta)
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})

        if from do
          GenServer.reply(from, {:ok, text})
        else
          if task_id, do: Loomkin.Teams.Tasks.complete_task(task_id, text)
        end

        {:noreply, drain_queues(state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, {:loop_error, reason, msgs}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        Logger.error("[Agent:#{state.name}] Loop failed: #{inspect(reason)}")
        task_id = state.task && state.task[:id]

        state = %{state | messages: msgs, loop_task: nil}
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})

        if from do
          GenServer.reply(from, {:error, reason})
        else
          if task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, inspect(reason))
        end

        {:noreply, drain_queues(state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, {:loop_pending, pending_info, msgs}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        state = %{state | messages: msgs, pending_permission: pending_info, loop_task: nil}
        state = set_status(state, :waiting_permission)

        if from, do: GenServer.reply(from, {:ok, :pending_permission})

        {:noreply, drain_queues(state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        Logger.error("[Agent:#{state.name}] Loop task crashed: #{inspect(reason)}")
        task_id = state.task && state.task[:id]

        state = %{state | loop_task: nil}
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})

        if from do
          GenServer.reply(from, {:error, :crashed})
        else
          if task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "crashed: #{inspect(reason)}")
        end

        {:noreply, drain_queues(state)}

      _ ->
        {:noreply, state}
    end
  end

  # --- Priority dispatcher (active during loop) ---

  @impl true
  def handle_info(msg, %{loop_task: {_task, _from}} = state) when is_tuple(msg) do
    case PriorityRouter.classify(msg) do
      {:urgent, _type} ->
        handle_urgent(msg, state)

      {:high, _type} ->
        {:noreply, %{state | priority_queue: state.priority_queue ++ [msg]}}

      {:normal, _type} ->
        {:noreply, %{state | pending_updates: state.pending_updates ++ [msg]}}

      {:ignore, _type} ->
        {:noreply, state}
    end
  end

  # --- handle_info for PubSub (idle path) ---

  @impl true
  def handle_info({:context_update, from, payload}, state) do
    context = Map.put(state.context, from, payload)
    {:noreply, %{state | context: context}}
  end

  @impl true
  def handle_info({:agent_status, agent_name, status}, state) do
    if agent_name != state.name do
      Logger.debug("[Agent:#{state.name}] Peer #{agent_name} status: #{status}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:keeper_created, info}, state) do
    if info.source == to_string(state.name) do
      {:noreply, state}
    else
      keeper_msg = %{
        role: :system,
        content: "New keeper available: [#{info.id}] \"#{info.topic}\" by #{info.source} (#{info.tokens} tokens)"
      }

      {:noreply, %{state | messages: state.messages ++ [keeper_msg]}}
    end
  end

  @impl true
  def handle_info({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    {:noreply, %{state | messages: state.messages ++ [peer_msg]}}
  end

  @impl true
  def handle_info({:task_assigned, task_id, agent_name}, state) do
    if to_string(agent_name) == to_string(state.name) do
      Logger.info("[Agent:#{state.name}] Received task assignment: #{task_id}")

      case Loomkin.Teams.Tasks.get_task(task_id) do
        {:ok, task} ->
          # Only override model if the task has an explicit model_hint;
          # otherwise preserve the agent's current model (set at spawn from user's selection)
          task_map = %{id: task.id, description: task.description, title: task.title, model_hint: task.model_hint}
          model = if task.model_hint, do: ModelRouter.select(state.role, task_map), else: state.model
          state = %{state | task: task_map, model: model}
          messages = maybe_prefetch_context(state, state.task)
          state = %{state | messages: messages}

          if state.status == :idle do
            send(self(), {:auto_execute_task, task_id})
          end

          {:noreply, state}

        {:error, _} ->
          Logger.warning("[Agent:#{state.name}] Could not fetch task #{task_id}")
          {:noreply, state}
      end
    else
      Logger.debug("[Agent:#{state.name}] Task #{task_id} assigned to #{agent_name}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:auto_execute_task, task_id}, state) do
    if state.status != :idle || state.loop_task != nil do
      Logger.debug("[Agent:#{state.name}] Skipping auto-execute for #{task_id} — status is #{state.status}")
      {:noreply, state}
    else
      task = state.task
      description = task[:description] || task[:title] || "Complete task #{task_id}"
      Logger.info("[Agent:#{state.name}] Auto-executing task #{task_id}")

      state = set_status(state, :working)
      broadcast_team(state, {:agent_status, state.name, :working})

      user_message = %{role: :user, content: description}
      messages = state.messages ++ [user_message]
      loop_opts = build_loop_opts(state)
      snapshot = build_snapshot(state)

      async_task = Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
        run_loop_with_escalation(messages, loop_opts, snapshot)
      end)

      {:noreply, %{state | loop_task: {async_task, nil}}}
    end
  end

  @impl true
  def handle_info({:query, query_id, from, question, enrichments}, state) do
    # Don't process our own broadcast questions
    if from == to_string(state.name) do
      {:noreply, state}
    else
      enrichment_text =
        case enrichments do
          [] -> ""
          list -> "\n\nRelevant context:\n" <> Enum.join(list, "\n")
        end

      query_msg = %{
        role: :user,
        content: """
        [Query from #{from} | ID: #{query_id}]
        #{question}#{enrichment_text}

        You can respond using peer_answer_question with query_id "#{query_id}", \
        or forward the question to another agent if someone else is better suited to answer.\
        """
      }

      {:noreply, %{state | messages: state.messages ++ [query_msg]}}
    end
  end

  @impl true
  def handle_info({:query_answer, query_id, from, answer, enrichments}, state) do
    enrichment_text =
      case enrichments do
        [] -> ""
        list -> "\n\nEnrichments gathered during routing:\n" <> Enum.join(list, "\n")
      end

    answer_msg = %{
      role: :user,
      content: """
      [Answer from #{from} | Query: #{query_id}]
      #{answer}#{enrichment_text}\
      """
    }

    {:noreply, %{state | messages: state.messages ++ [answer_msg]}}
  end

  @impl true
  def handle_info({:sub_team_completed, sub_team_id}, state) do
    results =
      try do
        case Loomkin.Teams.Tasks.list_all(sub_team_id) do
          tasks when is_list(tasks) ->
            tasks
            |> Enum.filter(&(&1.status == :completed))
            |> Enum.map(fn t -> "- #{t.title}: #{String.slice(t.result || "", 0, 200)}" end)
            |> Enum.join("\n")

          _ ->
            ""
        end
      rescue
        _ -> ""
      end

    summary = if results != "", do: "\nResults:\n#{results}", else: ""
    msg = %{role: :system, content: "[System] Sub-team #{sub_team_id} completed and dissolved.#{summary}"}
    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:role_changed, agent_name, old_role, new_role}, state) do
    if agent_name != state.name do
      Logger.debug("[Agent:#{state.name}] Peer #{agent_name} changed role: #{old_role} -> #{new_role}")
    end

    {:noreply, state}
  end

  # --- Debate protocol handlers ---

  @impl true
  def handle_info({:debate_start, debate_id, topic, participants}, state) do
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{state.team_id}:debate:#{debate_id}")

    msg = %{
      role: :system,
      content:
        "[Debate #{debate_id}] Started on topic: #{topic}. Participants: #{Enum.join(participants, ", ")}"
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:debate_propose, debate_id, round_num, topic}, state) do
    spawn_debate_response(state, debate_id, :proposal, """
    [Debate round #{round_num}] Propose your solution for: #{topic}
    Respond with a clear, concise proposal.
    """)

    {:noreply, state}
  end

  @impl true
  def handle_info({:debate_critique, debate_id, round_num, proposals}, state) do
    proposals_text =
      Enum.map_join(proposals, "\n", fn p ->
        "- #{p.from}: #{p[:content] || p[:description] || inspect(p)}"
      end)

    spawn_debate_response(state, debate_id, :critique, """
    [Debate round #{round_num}] Critique these proposals:
    #{proposals_text}
    Provide specific, constructive feedback.
    """)

    {:noreply, state}
  end

  @impl true
  def handle_info({:debate_revise, debate_id, round_num, critiques}, state) do
    critiques_text =
      Enum.map_join(critiques, "\n", fn c ->
        "- #{c.from}: #{c[:content] || inspect(c)}"
      end)

    spawn_debate_response(state, debate_id, :revision, """
    [Debate round #{round_num}] Revise your proposal based on feedback:
    #{critiques_text}
    Provide your revised proposal.
    """)

    {:noreply, state}
  end

  @impl true
  def handle_info({:debate_vote, debate_id, proposals}, state) do
    proposals_text =
      Enum.map_join(proposals, "\n", fn p ->
        "- #{p.from}: #{p[:content] || p[:description] || inspect(p)}"
      end)

    spawn_debate_response(state, debate_id, :vote, """
    [Debate] Vote for the best proposal:
    #{proposals_text}
    Respond with only the name of the participant whose proposal you choose.
    """)

    {:noreply, state}
  end

  # --- Pair programming handlers ---

  @impl true
  def handle_info({:pair_started, pair_id, my_role, partner_name}, state) do
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{state.team_id}:pair:#{pair_id}")

    msg = %{
      role: :system,
      content:
        "[Pair #{pair_id}] You are the #{my_role} paired with #{partner_name}. " <>
          if(my_role == :reviewer,
            do: "Watch the coder's work and interject if you spot issues.",
            else: "Broadcast your intent before editing, and share diffs after changes."
          )
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:pair_stopped, pair_id}, state) do
    Phoenix.PubSub.unsubscribe(Loomkin.PubSub, "team:#{state.team_id}:pair:#{pair_id}")

    msg = %{role: :system, content: "[Pair #{pair_id}] Pair session ended."}
    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:pair_event, %{event: event, from: from, payload: payload}}, state) do
    summary =
      case event do
        :intent_broadcast -> "#{from} intends to: #{payload[:description] || inspect(payload)}"
        :file_edited -> "#{from} edited: #{payload[:file] || payload[:path] || inspect(payload)}"
        :review_feedback -> "#{from} feedback: #{payload[:feedback] || inspect(payload)}"
        :review_approved -> "#{from} approved the changes"
        :review_rejected -> "#{from} rejected: #{payload[:reason] || inspect(payload)}"
        other -> "#{from}: #{other} #{inspect(payload)}"
      end

    msg = %{role: :system, content: "[Pair] #{summary}"}
    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  # --- Loop resumed after permission response ---

  @impl true
  def handle_info({:loop_resumed, {:ok, response_text, messages, metadata}}, state) do
    task_id = state.task && state.task[:id]
    if task_id, do: ModelRouter.record_success(state.team_id, state.name, task_id, state.model)

    state = %{state | messages: messages, failure_count: 0}
    state = track_usage(state, metadata)
    state = set_status(state, :idle)
    broadcast_team(state, {:agent_status, state.name, :idle})

    # If there's an active task, complete it with the response
    if task_id do
      Loomkin.Teams.Tasks.complete_task(task_id, response_text)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:loop_resumed, {:error, reason, messages}}, state) do
    Logger.error("[Agent:#{state.name}] Resumed loop failed: #{inspect(reason)}")
    state = %{state | messages: messages}
    state = set_status(state, :idle)
    broadcast_team(state, {:agent_status, state.name, :idle})
    {:noreply, state}
  end

  @impl true
  def handle_info({:loop_resumed, {:pending_permission, new_pending, messages}}, state) do
    state = %{state | messages: messages, pending_permission: new_pending}
    state = set_status(state, :waiting_permission)
    {:noreply, state}
  end

  @impl true
  def handle_info({:request_review, from, %{file: file, changes: changes} = payload}, state) do
    question_text =
      case payload[:question] do
        nil -> ""
        q -> "\nQuestion: #{q}"
      end

    review_msg = %{
      role: :user,
      content: """
      [Review Request from #{from}]
      File: #{file}
      Changes:
      #{changes}#{question_text}

      Please review these changes and provide feedback using peer_message.\
      """
    }

    {:noreply, %{state | messages: state.messages ++ [review_msg]}}
  end

  @impl true
  def handle_info({:tasks_unblocked, task_ids}, state) do
    Logger.debug("[Agent:#{state.name}] Tasks unblocked: #{inspect(task_ids)}")

    msg = %{
      role: :system,
      content: "[System] Tasks now available: #{Enum.join(task_ids, ", ")}. Use team_progress to see details."
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:role_change_request, agent_name, old_role, new_role, _request_id}, state) do
    Logger.debug("[Agent:#{state.name}] Role change request: #{agent_name} #{old_role} -> #{new_role}")
    {:noreply, state}
  end

  # --- Nervous system handlers ---

  @impl true
  def handle_info({:discovery_relevant, payload}, state) do
    %{observation_title: obs_title, goal_title: goal_title, source_agent: source, keeper_id: keeper_id} = payload

    msg = "[Discovery from #{source}] #{obs_title} — relevant to your goal: #{goal_title}"
    msg = if keeper_id, do: msg <> "\n  → Full context: context_retrieve on keeper #{keeper_id}", else: msg

    messages = state.messages ++ [%{role: :user, content: msg}]
    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_info({:confidence_warning, payload}, state) do
    %{source_title: title, source_confidence: conf, affected_title: affected, keeper_id: keeper_id} = payload

    msg = "[Confidence Warning] Upstream decision '#{title}' has low confidence (#{conf}). Your work on '#{affected}' may be affected."
    msg = if keeper_id, do: msg <> "\n  → Re-evaluate using keeper #{keeper_id}", else: msg

    messages = state.messages ++ [%{role: :user, content: msg}]
    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_info({:vote_request, vote_id, topic, options, scope}, state) do
    options_text = Enum.map_join(options, "\n", fn opt -> "- #{opt}" end)

    spawn_vote_response(state, vote_id, topic, options, """
    [Collective Vote] Topic: #{topic} (scope: #{scope})
    Options:
    #{options_text}

    Choose one of the options above. Respond with ONLY the exact option text and nothing else.
    """)

    {:noreply, state}
  end

  @impl true
  def handle_info({:inject_system_message, content}, state) do
    msg = %{role: :system, content: content}
    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp do_change_role(state, new_role) do
    case Role.get(new_role) do
      {:ok, role_config} ->
        old_role = state.role

        state = %{state |
          role: new_role,
          role_config: role_config,
          tools: role_config.tools
        }

        # Update Registry metadata
        Registry.update_value(Loomkin.Teams.AgentRegistry, {state.team_id, state.name}, fn _old ->
          %{role: new_role, status: state.status}
        end)

        # Update Context agent info
        Context.register_agent(state.team_id, state.name, %{
          role: new_role,
          status: state.status,
          model: state.model
        })

        # Log role transition to decision graph
        log_role_change_to_graph(state.team_id, state.name, old_role, new_role)

        # Broadcast role change to team
        broadcast_team(state, {:role_changed, state.name, old_role, new_role})

        Logger.info("[Agent:#{state.name}] Role changed from #{old_role} to #{new_role}")

        {:reply, :ok, state}

      {:error, :unknown_role} ->
        {:reply, {:error, :unknown_role}, state}
    end
  end

  defp log_role_change_to_graph(team_id, agent_name, old_role, new_role) do
    Loomkin.Decisions.Graph.add_node(%{
      node_type: :observation,
      title: "Role change: #{agent_name} #{old_role} -> #{new_role}",
      description: "Agent #{agent_name} in team #{team_id} changed role from #{old_role} to #{new_role}.",
      status: :active,
      session_id: team_id
    })
  rescue
    _ -> :ok
  end

  defp spawn_vote_response(state, vote_id, _topic, options, prompt) do
    team_id = state.team_id
    agent_name = to_string(state.name)
    model = state.model
    messages = state.messages ++ [%{role: :user, content: prompt}]

    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      loop_opts = [
        model: model,
        tools: [],
        system_prompt: "You are voting in a collective decision. Respond with only the chosen option text.",
        project_path: state.project_path
      ]

      response_text =
        case AgentLoop.run(messages, loop_opts) do
          {:ok, text, _msgs, _meta} -> String.trim(text)
          _ -> List.first(options) || "abstain"
        end

      # Match response to closest option
      choice =
        Enum.find(options, response_text, fn opt ->
          String.downcase(opt) == String.downcase(response_text)
        end)

      response = %{from: agent_name, choice: choice, confidence: 0.5}

      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "team:#{team_id}:vote:#{vote_id}",
        {:vote_response, vote_id, response}
      )
    end)
  end

  defp spawn_debate_response(state, debate_id, phase, prompt) do
    team_id = state.team_id
    agent_name = to_string(state.name)
    model = state.model
    messages = state.messages ++ [%{role: :user, content: prompt}]

    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      loop_opts = [
        model: model,
        tools: [],
        system_prompt: "You are participating in a structured debate. Respond concisely.",
        project_path: state.project_path
      ]

      response_text =
        case AgentLoop.run(messages, loop_opts) do
          {:ok, text, _msgs, _meta} -> text
          _ -> "No response"
        end

      response =
        case phase do
          :vote -> %{from: agent_name, choice: response_text}
          _ -> %{from: agent_name, content: response_text}
        end

      Loomkin.Teams.Debate.submit_response(team_id, debate_id, phase, response)
    end)
  end

  defp run_loop_with_escalation(messages, loop_opts, snapshot) do
    case AgentLoop.run(messages, loop_opts) do
      {:ok, text, msgs, meta} ->
        {:loop_ok, text, msgs, meta}

      {:error, reason, msgs} ->
        maybe_escalate_in_task(reason, msgs, loop_opts, snapshot)

      {:pending_permission, info, msgs} ->
        {:loop_pending, info, msgs}
    end
  end

  defp maybe_escalate_in_task(reason, messages, loop_opts, snapshot) do
    task_id = snapshot.task && snapshot.task[:id]

    if task_id do
      ModelRouter.record_failure(snapshot.team_id, snapshot.name, task_id)

      if ModelRouter.escalation_enabled?() &&
           ModelRouter.should_escalate?(snapshot.team_id, snapshot.name, task_id) &&
           snapshot.failure_count < 1 do
        do_escalate_in_task(reason, messages, loop_opts, snapshot)
      else
        {:loop_error, reason, messages}
      end
    else
      {:loop_error, reason, messages}
    end
  end

  defp do_escalate_in_task(reason, messages, loop_opts, snapshot) do
    old_model = snapshot.model

    case ModelRouter.escalate(old_model) do
      {:ok, next_model} ->
        Logger.info("[Agent:#{snapshot.name}] Escalating from #{old_model} to #{next_model}")

        CostTracker.record_escalation(
          snapshot.team_id,
          to_string(snapshot.name),
          old_model,
          next_model
        )

        :telemetry.execute([:loomkin, :team, :escalation], %{}, %{
          team_id: snapshot.team_id,
          agent_name: to_string(snapshot.name),
          from_model: old_model,
          to_model: next_model
        })

        Phoenix.PubSub.broadcast(
          Loomkin.PubSub,
          "team:#{snapshot.team_id}",
          {:agent_escalation, snapshot.name, old_model, next_model}
        )

        # Refresh project_path from ETS so escalation uses the latest directory
        fresh_path = resolve_project_path(snapshot.team_id, Keyword.get(loop_opts, :project_path))

        new_loop_opts =
          loop_opts
          |> Keyword.put(:model, next_model)
          |> Keyword.put(:project_path, fresh_path)

        case AgentLoop.run(messages, new_loop_opts) do
          {:ok, text, msgs, meta} ->
            {:loop_ok_escalated, text, msgs, meta, next_model}

          {:error, _reason, _msgs} ->
            {:loop_error, reason, messages}

          {:pending_permission, _info, _msgs} ->
            {:loop_error, reason, messages}
        end

      :max_reached ->
        {:loop_error, reason, messages}

      :disabled ->
        {:loop_error, reason, messages}
    end
  end

  defp build_snapshot(state) do
    %{
      team_id: state.team_id,
      name: state.name,
      model: state.model,
      task: state.task,
      failure_count: state.failure_count,
      role: state.role
    }
  end

  defp drain_queues(state) do
    Enum.each(state.priority_queue, fn msg -> send(self(), msg) end)
    Enum.each(state.pending_updates, fn msg -> send(self(), msg) end)
    %{state | priority_queue: [], pending_updates: []}
  end

  defp handle_urgent({:abort_task, _reason}, state) do
    case state.loop_task do
      {%Task{} = task, from} ->
        Task.shutdown(task, :brutal_kill)
        task_id = state.task && state.task[:id]
        if task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "aborted")
        if from, do: GenServer.reply(from, {:error, :aborted})
        state = %{state | loop_task: nil, pending_updates: [], priority_queue: []}
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_urgent({:budget_exceeded, _scope}, state) do
    case state.loop_task do
      {%Task{} = task, from} ->
        Task.shutdown(task, :brutal_kill)
        task_id = state.task && state.task[:id]
        if from, do: GenServer.reply(from, {:error, :budget_exceeded})
        if !from && task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "budget exceeded")
        state = %{state | loop_task: nil, pending_updates: [], priority_queue: []}
        state = set_status(state, :idle)
        broadcast_team(state, {:agent_status, state.name, :idle})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_urgent({:file_conflict, details}, state) do
    # Queue as an internal message so it survives the loop result handler
    # (which overwrites state.messages with the task-returned msgs).
    inject = {:inject_system_message, "[URGENT] File conflict detected: #{inspect(details)}"}
    {:noreply, %{state | priority_queue: state.priority_queue ++ [inject]}}
  end

  defp handle_urgent(_msg, state), do: {:noreply, state}

  @doc false
  def resolve_project_path(team_id, fallback) do
    Manager.get_team_project_path(team_id) || fallback
  end

  defp build_loop_opts(state) do
    team_id = state.team_id
    name = state.name
    system_prompt = inject_keeper_index(state.role_config.system_prompt, team_id)
    permission_callback = build_permission_callback(state)

    # A resolver fn allows AgentLoop to read the latest project_path from
    # team ETS at every tool call, even when the Task captured stale opts.
    project_path_resolver = fn -> resolve_project_path(team_id, state.project_path) end

    [
      model: state.model,
      tools: state.tools,
      system_prompt: system_prompt,
      project_path: state.project_path,
      project_path_resolver: project_path_resolver,
      agent_name: state.name,
      team_id: state.team_id,
      check_permission: permission_callback,
      rate_limiter: fn provider ->
        RateLimiter.acquire(provider, 1000)
      end,
      on_event: fn event_name, payload ->
        handle_loop_event(team_id, name, event_name, payload)
      end,
      on_tool_execute: fn tool_module, tool_args, context ->
        # Inject agent messages into context for ContextOffload to avoid deadlock.
        context =
          if tool_module == Loomkin.Tools.ContextOffload do
            Map.put(context, :agent_messages, state.messages)
          else
            context
          end

        # AskUser blocks waiting for human input (up to 5 min), so bypass the
        # default 60s Jido.Exec timeout and call run/2 directly.
        if tool_module == Loomkin.Tools.AskUser do
          atomized = Loomkin.Tools.Registry.atomize_keys(tool_args)

          result =
            try do
              tool_module.run(atomized, context)
            rescue
              e -> {:error, Exception.message(e)}
            end

          AgentLoop.format_tool_result(result)
        else
          AgentLoop.default_run_tool(tool_module, tool_args, context)
        end
      end
    ]
  end

  defp build_permission_callback(%{permission_mode: :auto}), do: nil

  defp build_permission_callback(%{
         permission_mode: :session,
         team_id: team_id,
         name: name
       }) do
    agent_name = name

    fn tool_name, tool_path ->
      tool_name_str = to_string(tool_name)

      # Dynamically resolve project_path so permission checks use the latest directory
      project_path = resolve_project_path(team_id, nil)

      # Resolve path to absolute for display and permission checking
      resolved_path =
        if project_path do
          Loomkin.Tool.resolve_path(tool_path, project_path)
        else
          tool_path
        end

      check_result =
        if project_path do
          Loomkin.Permissions.Manager.check(tool_name_str, tool_path, team_id, project_path)
        else
          Loomkin.Permissions.Manager.check(tool_name_str, tool_path, team_id)
        end

      case check_result do
        :allowed ->
          :allowed

        :ask ->
          Phoenix.PubSub.broadcast(
            Loomkin.PubSub,
            "team:#{team_id}",
            {:permission_request, team_id, tool_name_str, resolved_path,
             {:agent, team_id, agent_name}}
          )

          {:pending, %{tool_name: tool_name_str, tool_path: resolved_path}}
      end
    end
  end

  defp build_permission_callback(_state), do: nil

  defp maybe_prefetch_context(state, task) do
    task_description = task[:description] || task[:text] || to_string(task[:id] || "")

    if task_description == "" do
      state.messages
    else
      case ContextRetrieval.search(state.team_id, task_description) do
        [%{relevance: relevance, id: id} | _] when relevance > 0 ->
          case ContextRetrieval.retrieve(state.team_id, task_description, keeper_id: id) do
            {:ok, context} when is_binary(context) ->
              prefetch_msg = %{
                role: :system,
                content: "Pre-fetched context for your task:\n#{context}"
              }

              state.messages ++ [prefetch_msg]

            {:ok, context} when is_list(context) ->
              formatted =
                Enum.map_join(context, "\n", fn msg ->
                  "#{msg[:role] || msg["role"]}: #{msg[:content] || msg["content"]}"
                end)

              prefetch_msg = %{
                role: :system,
                content: "Pre-fetched context for your task:\n#{formatted}"
              }

              state.messages ++ [prefetch_msg]

            _ ->
              state.messages
          end

        _ ->
          state.messages
      end
    end
  rescue
    _ -> state.messages
  end

  defp inject_keeper_index(prompt, team_id) do
    keepers = ContextRetrieval.list_keepers(team_id)

    index_text =
      case keepers do
        [] ->
          "none yet"

        list ->
          Enum.map_join(list, "\n", fn k ->
            "- [#{k.id}] \"#{k.topic}\" by #{k.source_agent} (#{k.token_count} tokens)"
          end)
      end

    if String.contains?(prompt, "{keeper_index}") do
      String.replace(prompt, "{keeper_index}", index_text)
    else
      prompt <> "\n\nAvailable Keepers:\n" <> index_text
    end
  end

  defp handle_loop_event(team_id, agent_name, event_name, payload) do
    topic = "team:#{team_id}"

    case event_name do
      :stream_start ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:agent_stream_start, agent_name, payload})

      :stream_delta ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:agent_stream_delta, agent_name, payload})

      :stream_end ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:agent_stream_end, agent_name, payload})

      :tool_executing ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:tool_executing, agent_name, payload})

      :tool_complete ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:tool_complete, agent_name, payload})

      :usage ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:usage, agent_name, payload})

      :context_offloaded ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:context_offloaded, agent_name, payload})

      :tool_error ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:agent_error, agent_name, payload})

      :max_iterations_exceeded ->
        Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:agent_error, agent_name, payload})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp track_usage(state, %{usage: usage}) do
    total_tokens = (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
    cost = usage[:total_cost] || 0

    case RateLimiter.record_usage(state.team_id, to_string(state.name), %{
           tokens: total_tokens,
           cost: cost
         }) do
      {:budget_exceeded, scope} ->
        Logger.warning("[Agent:#{state.name}] Budget exceeded (#{scope})")

      :ok ->
        :ok
    end

    CostTracker.record_usage(state.team_id, to_string(state.name), %{
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost,
      model: state.model
    })

    CostTracker.record_call(state.team_id, to_string(state.name), %{
      model: state.model,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost,
      task_id: state.task && state.task[:id]
    })

    # Emit telemetry for PubSub broadcast only — handlers must NOT
    # write back to CostTracker (already recorded above).
    :telemetry.execute([:loomkin, :team, :llm, :request, :stop], %{}, %{
      team_id: state.team_id,
      agent_name: to_string(state.name),
      model: state.model,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost
    })

    # Budget warning at 80% threshold
    budget = RateLimiter.get_budget(state.team_id)

    if budget.limit > 0 && budget.spent / budget.limit >= 0.8 do
      :telemetry.execute([:loomkin, :team, :budget, :warning], %{}, %{
        team_id: state.team_id,
        spent: budget.spent,
        limit: budget.limit,
        threshold: 0.8
      })
    end

    %{
      state
      | cost_usd: state.cost_usd + cost,
        tokens_used: state.tokens_used + total_tokens
    }
  end

  defp track_usage(state, _metadata), do: state

  defp set_status(state, new_status) do
    Registry.update_value(Loomkin.Teams.AgentRegistry, {state.team_id, state.name}, fn _old ->
      %{role: state.role, status: new_status}
    end)

    Context.update_agent_status(state.team_id, state.name, new_status)

    %{state | status: new_status}
  end

  defp broadcast_team(state, event) do
    Phoenix.PubSub.broadcast(Loomkin.PubSub, "team:#{state.team_id}", event)
  rescue
    _ -> :ok
  end
end
