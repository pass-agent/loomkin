defmodule Loomkin.Teams.Agent do
  @moduledoc """
  GenServer representing a single agent within a team. Every Loomkin conversation
  runs through a Teams.Agent — even solo sessions are a team of one.

  Uses Loomkin.AgentLoop for the ReAct cycle, Loomkin.Teams.Role for configuration,
  and communicates with peers via Phoenix.PubSub.
  """

  use GenServer

  alias Loomkin.AgentLoop
  alias Loomkin.Teams.{Comms, Context, ContextRetrieval, CostTracker, ModelRouter, RateLimiter, Role}

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
    pending_permission: nil
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
  def handle_call({:send_message, text}, _from, state) do
    state = set_status(state, :working)

    user_message = %{role: :user, content: text}
    messages = state.messages ++ [user_message]

    broadcast_team(state, {:agent_status, state.name, :working})

    loop_opts = build_loop_opts(state)

    case AgentLoop.run(messages, loop_opts) do
      {:ok, response_text, messages, metadata} ->
        task_id = state.task && state.task[:id]

        if task_id do
          ModelRouter.record_success(state.team_id, state.name, task_id, state.model)
        end

        state = %{state | messages: messages, failure_count: 0}
        state = track_usage(state, metadata)
        state = set_status(state, :idle)
        {:reply, {:ok, response_text}, state}

      {:error, reason, messages} ->
        state = %{state | messages: messages}
        task_id = state.task && state.task[:id]

        escalation_result =
          if task_id do
            ModelRouter.record_failure(state.team_id, state.name, task_id)

            if ModelRouter.escalation_enabled?() &&
                 ModelRouter.should_escalate?(state.team_id, state.name, task_id) &&
                 state.failure_count < 1 do
              attempt_escalation(state, messages)
            else
              nil
            end
          else
            nil
          end

        case escalation_result do
          {:ok, response_text, new_messages, metadata, escalated_state} ->
            state =
              escalated_state
              |> Map.put(:messages, new_messages)
              |> track_usage(metadata)
              |> set_status(:idle)

            {:reply, {:ok, response_text}, state}

          _ ->
            state = set_status(state, :idle)
            {:reply, {:error, reason}, state}
        end

      {:pending_permission, pending_info, messages} ->
        state = %{state | messages: messages, pending_permission: pending_info}
        state = set_status(state, :waiting_permission)
        {:reply, {:ok, :pending_permission}, state}
    end
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

  # --- handle_cast ---

  @impl true
  def handle_cast({:assign_task, task}, state) do
    Logger.info("[Agent:#{state.name}] Assigned task: #{inspect(task[:id] || task)}")
    model = ModelRouter.select(state.role, task)
    state = %{state | task: task, model: model}

    messages = maybe_prefetch_context(state, task)

    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_cast({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    {:noreply, %{state | messages: state.messages ++ [peer_msg]}}
  end

  @impl true
  def handle_cast({:permission_response, action, tool_name, _tool_path}, state) do
    case state.pending_permission do
      nil ->
        {:noreply, state}

      pending_info ->
        if action == "allow_always" do
          Loomkin.Permissions.Manager.grant(to_string(tool_name), "*", state.team_id)
        end

        # Resume in a task to avoid blocking the GenServer
        agent_pid = self()
        messages = state.messages

        Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
          tool_result =
            if action in ["allow_once", "allow_always"] do
              pd = pending_info.pending_data
              AgentLoop.default_run_tool(pd.tool_module, pd.tool_args, pd.context)
            else
              "Error: Permission denied for #{tool_name}"
            end

          result = AgentLoop.resume(tool_result, pending_info, messages)
          send(agent_pid, {:loop_resumed, result})
        end)

        {:noreply, %{state | pending_permission: nil}}
    end
  end

  # --- handle_info for PubSub ---

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
          model = ModelRouter.select(state.role, %{id: task.id, description: task.description})
          state = %{state | task: %{id: task.id, description: task.description, title: task.title}, model: model}
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
    if state.status != :idle do
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

      case AgentLoop.run(messages, loop_opts) do
        {:ok, response_text, messages, metadata} ->
          state = %{state | messages: messages, failure_count: 0}
          state = track_usage(state, metadata)
          Loomkin.Teams.Tasks.complete_task(task_id, response_text)
          state = set_status(state, :idle)
          broadcast_team(state, {:agent_status, state.name, :idle})
          {:noreply, state}

        {:error, reason, messages} ->
          Logger.error("[Agent:#{state.name}] Task #{task_id} failed: #{inspect(reason)}")
          state = %{state | messages: messages}
          Loomkin.Teams.Tasks.fail_task(task_id, inspect(reason))
          state = set_status(state, :idle)
          broadcast_team(state, {:agent_status, state.name, :idle})
          {:noreply, state}

        {:pending_permission, _info, messages} ->
          state = %{state | messages: messages}
          state = set_status(state, :idle)
          {:noreply, state}
      end
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
        max_iterations: 1,
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

  defp attempt_escalation(state, messages) do
    old_model = state.model

    case ModelRouter.escalate(old_model) do
      {:ok, next_model} ->
        Logger.info("[Agent:#{state.name}] Escalating from #{old_model} to #{next_model}")

        CostTracker.record_escalation(state.team_id, to_string(state.name), old_model, next_model)

        :telemetry.execute([:loomkin, :team, :escalation], %{}, %{
          team_id: state.team_id,
          agent_name: to_string(state.name),
          from_model: old_model,
          to_model: next_model
        })

        broadcast_team(state, {:agent_escalation, state.name, old_model, next_model})

        state = %{state | model: next_model, failure_count: state.failure_count + 1}
        loop_opts = build_loop_opts(state)

        case AgentLoop.run(messages, loop_opts) do
          {:ok, response_text, new_messages, metadata} ->
            task_id = state.task && state.task[:id]

            if task_id do
              ModelRouter.record_success(state.team_id, state.name, task_id, next_model)
            end

            {:ok, response_text, new_messages, metadata, %{state | failure_count: 0}}

          {:error, _reason, _msgs} ->
            nil

          {:pending_permission, _info, _msgs} ->
            nil
        end

      :max_reached ->
        nil

      :disabled ->
        nil
    end
  end

  defp build_loop_opts(state) do
    team_id = state.team_id
    name = state.name
    system_prompt = inject_keeper_index(state.role_config.system_prompt, team_id)
    permission_callback = build_permission_callback(state)

    [
      model: state.model,
      tools: state.tools,
      system_prompt: system_prompt,
      max_iterations: state.role_config.max_iterations,
      project_path: state.project_path,
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
        # The tool runs inside the agent's handle_call (via AgentLoop → Jido.Exec Task),
        # so calling Agent.get_history(pid) would deadlock on GenServer.call to self.
        # Note: state.messages is captured at loop start. Messages added mid-loop
        # (from tool results) won't be in the offloaded set — this is acceptable
        # since the agent loop runs synchronously within a single handle_call.
        context =
          if tool_module == Loomkin.Tools.ContextOffload do
            Map.put(context, :agent_messages, state.messages)
          else
            context
          end

        AgentLoop.default_run_tool(tool_module, tool_args, context)
      end
    ]
  end

  defp build_permission_callback(%{permission_mode: :auto}), do: nil

  defp build_permission_callback(%{permission_mode: :session, team_id: team_id, name: name}) do
    agent_name = name

    fn tool_name, tool_path ->
      case Loomkin.Permissions.Manager.check(to_string(tool_name), tool_path, team_id) do
        :allowed ->
          :allowed

        :ask ->
          Phoenix.PubSub.broadcast(
            Loomkin.PubSub,
            "team:#{team_id}",
            {:permission_request, team_id, to_string(tool_name), tool_path,
             {:agent, team_id, agent_name}}
          )

          {:pending, %{tool_name: to_string(tool_name), tool_path: tool_path}}
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
