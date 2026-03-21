defmodule Loomkin.Teams.Agent do
  @moduledoc """
  GenServer representing a single agent within a team. Every Loomkin conversation
  runs through a Teams.Agent — even solo sessions are a team of one.

  Uses Loomkin.AgentLoop for the ReAct cycle, Loomkin.Teams.Role for configuration,
  and communicates with peers via Jido Signal Bus.
  """

  use GenServer

  require Logger

  alias Loomkin.AgentLoop
  alias Loomkin.Checkpoints
  alias Loomkin.Teams.AgentState
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Context
  alias Loomkin.Teams.ContextRetrieval
  alias Loomkin.Teams.CostTracker
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.ModelRouter
  alias Loomkin.Teams.PriorityRouter
  alias Loomkin.Teams.QueuedMessage
  alias Loomkin.Teams.RateLimiter
  alias Loomkin.Teams.Role
  alias Loomkin.Teams.ScopeDetector

  @type t :: %__MODULE__{}

  defstruct [
    :team_id,
    :session_id,
    :name,
    :role,
    :role_config,
    :status,
    :model,
    :project_path,
    # Cached from KinAgent DB record at init to avoid a per-loop DB query.
    system_prompt_extra: nil,
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
    priority_queue: [],
    pause_requested: false,
    pause_queued: false,
    paused_state: nil,
    frozen_state: nil,
    healing_queue: [],
    subscription_ids: [],
    last_asked_at: nil,
    pending_ask_user: nil,
    spawned_child_teams: [],
    auto_approve_spawns: false,
    wake_ref: nil,
    scope_tier: nil,
    files_touched: MapSet.new(),
    task_cost_usd: 0.0
  ]

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loomkin.Teams.AgentRegistry, {team_id, name},
          %{role: opts[:role], status: :idle, model: opts[:model]}}}
    )
  end

  @doc "Send a user message to this agent and get the response."
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  @doc """
  Injects a broadcast message into a paused agent's message history.
  If the agent is not paused (no paused_state), falls back to send_message/2.
  """
  def inject_broadcast(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:inject_broadcast, text})
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
    GenServer.call(pid, :get_status, 15_000)
  end

  @doc "Get conversation history."
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  @doc "Cancel an in-progress agent loop."
  def cancel(pid), do: GenServer.call(pid, :cancel, 15_000)

  @doc "Request the agent to pause at the next checkpoint."
  def request_pause(pid) do
    GenServer.cast(pid, :request_pause)
  end

  @doc "Force-pause an agent that is waiting for permission, cancelling the pending permission."
  def force_pause(pid) do
    GenServer.call(pid, :force_pause)
  end

  @doc "Resume a paused agent, optionally injecting guidance text."
  def resume(pid, opts \\ []) do
    GenServer.call(pid, {:resume, opts}, 15_000)
  end

  @doc "Inject steering guidance and resume a paused agent."
  def steer(pid, guidance) when is_binary(guidance) do
    GenServer.call(pid, {:resume, guidance: guidance}, 15_000)
  end

  @doc "Enqueue a user message without sending immediately (queues even if agent is idle)."
  def enqueue(pid, text, opts \\ []) when is_pid(pid) and is_binary(text) do
    GenServer.call(pid, {:enqueue, text, opts}, 15_000)
  end

  @doc "List all queued messages (returns both queues merged, priority first)."
  def list_queue(pid) when is_pid(pid) do
    GenServer.call(pid, :list_queue, 15_000)
  end

  @doc "Edit content of a queued message by ID."
  def edit_queued(pid, message_id, new_content) when is_pid(pid) and is_binary(message_id) do
    GenServer.call(pid, {:edit_queued, message_id, new_content}, 15_000)
  end

  @doc "Reorder queue -- takes list of message IDs in desired order."
  def reorder_queue(pid, queue_type, ordered_ids)
      when is_pid(pid) and queue_type in [:priority, :pending] and is_list(ordered_ids) do
    GenServer.call(pid, {:reorder_queue, queue_type, ordered_ids}, 15_000)
  end

  @doc "Squash multiple queued messages into one."
  def squash_queued(pid, message_ids, opts \\ [])
      when is_pid(pid) and is_list(message_ids) do
    GenServer.call(pid, {:squash_queued, message_ids, opts}, 15_000)
  end

  @doc "Delete a queued message by ID."
  def delete_queued(pid, message_id) when is_pid(pid) and is_binary(message_id) do
    GenServer.call(pid, {:delete_queued, message_id}, 15_000)
  end

  @doc "Inject guidance without pausing (non-disruptive steer)."
  def inject_guidance(pid, text) when is_pid(pid) and is_binary(text) do
    GenServer.call(pid, {:inject_guidance, text}, 15_000)
  end

  @doc "Send a permission response to this agent."
  def permission_response(pid, action, tool_name, tool_path) do
    GenServer.cast(pid, {:permission_response, action, tool_name, tool_path})
  end

  @doc "Update the project path for this agent."
  def update_project_path(pid, new_path) do
    GenServer.cast(pid, {:update_project_path, new_path})
  end

  @doc "Update the model on a running agent."
  def update_model(pid, new_model) do
    GenServer.cast(pid, {:update_model, new_model})
  end

  @doc "Get the full GenServer state (for serialization/migration)."
  def get_state(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_state, timeout)
  end

  @doc """
  Change the role of this agent.

  ## Options
    * `:role_config` - a pre-built `%Role{}` config (skips Role.get lookup)
    * `:require_approval` - if true, sends approval request to team lead before changing (default: false)
  """
  def change_role(pid, new_role, opts \\ []) when is_pid(pid) do
    if opts == [] do
      GenServer.call(pid, {:change_role, new_role}, :infinity)
    else
      GenServer.call(pid, {:change_role, new_role, opts}, :infinity)
    end
  end

  @doc "Wake an agent from :suspended_healing status with a healing summary."
  def wake_from_healing(pid, healing_summary) when is_pid(pid) do
    GenServer.cast(pid, {:wake_from_healing, healing_summary})
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)
    role = Keyword.fetch!(opts, :role)
    project_path = Keyword.get(opts, :project_path)

    permission_mode = Keyword.get(opts, :permission_mode, :auto)
    session_id = Keyword.get(opts, :session_id)
    kin_agents = Keyword.get(opts, :kin_agents, [])

    Logger.info("[Kin:agent] init name=#{name} role=#{role} team=#{team_id}")
    Logger.metadata(agent: name, role: role, team: team_id)

    role_result =
      case Keyword.get(opts, :role_config) do
        %Role{} = config -> {:ok, config}
        _ -> Role.get(role, kin_agents: kin_agents)
      end

    case role_result do
      {:ok, role_config} ->
        model = Keyword.get(opts, :model) || ModelRouter.default_model()

        {:ok, sub_ids} = Comms.subscribe(team_id, name, role: role)

        # Look up system_prompt_extra from the kin_agents list passed at spawn time
        # (already scoped to the session's user) rather than a global DB query.
        system_prompt_extra =
          case Enum.find(kin_agents, fn kin -> kin.name == to_string(name) end) do
            %{system_prompt_extra: extra} when is_binary(extra) and extra != "" -> extra
            _ -> nil
          end

        state = %__MODULE__{
          team_id: team_id,
          session_id: session_id,
          name: name,
          role: role,
          role_config: role_config,
          status: :idle,
          model: model,
          project_path: project_path,
          tools: role_config.tools,
          permission_mode: permission_mode,
          subscription_ids: sub_ids,
          system_prompt_extra: system_prompt_extra
        }

        # Attempt checkpoint restore before broadcasting
        state = maybe_restore_from_checkpoint(state)

        # Monitor via AgentWatcher BEFORE init completes — guarantees no gap
        # where a crash could be missed (previously called after start_child returned)
        Loomkin.Teams.AgentWatcher.watch(Loomkin.Teams.AgentWatcher, self(), team_id, name)

        Context.register_agent(team_id, name, %{role: role, status: state.status, model: model})
        broadcast_team(state, {:agent_status, state.name, state.status})

        Logger.info(
          "[Kin:agent] registered name=#{name} role=#{role} — broadcasting :#{state.status}"
        )

        {:ok, state}

      {:error, :unknown_role} ->
        Logger.error("[Kin:agent] UNKNOWN ROLE #{inspect(role)} for #{name}")
        {:stop, {:unknown_role, role}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "[Kin:agent] terminating name=#{state.name} team=#{state.team_id} reason=#{inspect(reason)}"
    )

    # Dissolve all child teams spawned by this leader to prevent zombie teams after OTP restart
    for child_team_id <- state.spawned_child_teams do
      Logger.info("[Kin:agent] dissolving child team=#{child_team_id} on terminate")

      try do
        Manager.dissolve_team(child_team_id)
      catch
        :exit, reason ->
          Logger.warning(
            "[Kin:agent] failed to dissolve child team on terminate name=#{state.name} team=#{state.team_id} child_team=#{child_team_id} reason=#{inspect(reason)}"
          )
      end
    end

    # Save crash checkpoint synchronously (terminate must be fast but checkpoint is critical)
    if reason != :normal and reason != :shutdown do
      save_checkpoint_sync(state, :crashed, inspect(reason))
    end

    Comms.unsubscribe(state.subscription_ids)
  end

  # --- handle_call ---

  @impl true
  def handle_call({:send_message, _text}, _from, %{loop_task: {_, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call({:send_message, text}, from, state) do
    Logger.info(
      "[Kin:agent] #{state.name} received message, loop_active=#{state.loop_task != nil}"
    )

    state = set_status_and_broadcast(state, :working)

    # Register a tracked task if the agent doesn't already have one
    state =
      if is_nil(state.task) do
        task_id = "msg_#{state.team_id}_#{state.name}_#{System.unique_integer([:positive])}"
        title = String.slice(text, 0, 80)

        Context.cache_task(state.team_id, task_id, %{
          title: title,
          status: :in_progress,
          owner: state.name
        })

        %{state | task: %{id: task_id, title: title}}
      else
        state
      end

    user_message = %{role: :user, content: text}
    messages = state.messages ++ [user_message]

    loop_opts = build_loop_opts(state)
    snapshot = build_snapshot(state)

    task =
      Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
        run_loop_with_escalation(messages, loop_opts, snapshot)
      end)

    Logger.debug("[Kin:loop] spawned agent=#{state.name} ref=#{inspect(task.ref)}")

    {:noreply, %{state | loop_task: {task, from}}}
  end

  # Inject broadcast into paused agent's message history without starting a loop
  @impl true
  def handle_call({:inject_broadcast, text}, _from, %{status: :paused, paused_state: ps} = state)
      when ps != nil do
    user_message = %{role: :user, content: text}
    updated_ps = %{ps | messages: ps.messages ++ [user_message]}
    {:reply, :ok, %{state | paused_state: updated_ps}}
  end

  # Suspended healing agents queue broadcasts into frozen state
  @impl true
  def handle_call(
        {:inject_broadcast, text},
        _from,
        %{status: :suspended_healing, frozen_state: fs} = state
      )
      when fs != nil do
    user_message = %{role: :user, content: text}
    updated_fs = %{fs | messages: fs.messages ++ [user_message]}
    {:reply, :ok, %{state | frozen_state: updated_fs}}
  end

  # Completed or errored agents ignore broadcasts
  @impl true
  def handle_call({:inject_broadcast, _text}, _from, %{status: status} = state)
      when status in [:complete, :error] do
    {:reply, :ok, state}
  end

  # For non-paused agents, delegate to send_message
  @impl true
  def handle_call({:inject_broadcast, text}, from, state) do
    handle_call({:send_message, text}, from, state)
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
  def handle_call({:change_role, new_role}, _from, state) do
    do_change_role(state, new_role, nil)
  end

  @impl true
  def handle_call({:change_role, new_role, opts}, _from, state) do
    role_config = opts[:role_config]

    if opts[:require_approval] do
      # Send approval request to lead and wait synchronously
      request_id = Ecto.UUID.generate()

      Comms.broadcast(
        state.team_id,
        {:role_change_request, state.name, state.role, new_role, request_id}
      )

      # For now, pending approval proceeds immediately — the lead can reject via PubSub
      # A full interactive approval flow would require async state, which we avoid here.
      do_change_role(state, new_role, role_config)
    else
      do_change_role(state, new_role, role_config)
    end
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    case state.loop_task do
      {%Task{} = task, original_from} ->
        Task.shutdown(task, :brutal_kill)
        task_id = state.task && state.task[:id]
        if original_from, do: GenServer.reply(original_from, {:error, :cancelled})
        if !original_from && task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "cancelled")

        state = %{
          state
          | loop_task: nil,
            pending_permission: nil,
            pending_updates: [],
            priority_queue: [],
            pause_queued: false,
            pause_requested: false
        }

        state = set_status_and_broadcast(state, :idle)
        {:reply, :ok, state}

      nil when state.pending_permission != nil ->
        # Agent is waiting on permission — clear it and go idle
        state = %{
          state
          | pending_permission: nil,
            pending_updates: [],
            priority_queue: [],
            pause_queued: false,
            pause_requested: false
        }

        state = set_status_and_broadcast(state, :idle)
        {:reply, :ok, state}

      nil when state.status == :paused ->
        # Agent is paused — cancel clears paused state
        state = %{
          state
          | paused_state: nil,
            pause_requested: false,
            pause_queued: false,
            pending_updates: [],
            priority_queue: []
        }

        state = set_status_and_broadcast(state, :idle)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_task_running}, state}
    end
  end

  @impl true
  def handle_call({:checkpoint, _checkpoint}, _from, %{pause_requested: true} = state) do
    {:reply, {:pause, :user_requested}, state}
  end

  def handle_call({:checkpoint, _checkpoint}, _from, state) do
    case check_scope_envelope(state) do
      :ok ->
        {:reply, :continue, state}

      {:exceeded, trigger, details} ->
        tier = state.scope_tier
        broadcast_scope_gate(state, tier, trigger, details)

        {:reply,
         {:pause,
          {:scope_gate,
           %{tier: tier, trigger: trigger, current: details.current, limit: details.limit}}},
         state}
    end
  end

  @impl true
  def handle_call({:enqueue, text, opts}, _from, state) do
    priority = Keyword.get(opts, :priority, :normal)
    source = Keyword.get(opts, :source, :user)
    metadata = Keyword.get(opts, :metadata, %{})

    qm =
      QueuedMessage.new(
        {:inject_system_message, text},
        priority: priority,
        source: source,
        metadata: metadata
      )

    state =
      if priority in [:urgent, :high] do
        %{state | priority_queue: state.priority_queue ++ [qm]}
      else
        %{state | pending_updates: state.pending_updates ++ [qm]}
      end

    broadcast_queue_update(state)
    {:reply, {:ok, qm.id}, state}
  end

  @impl true
  def handle_call(:list_queue, _from, state) do
    {:reply, list_full_queue(state), state}
  end

  @impl true
  def handle_call({:edit_queued, message_id, new_content}, _from, state) do
    {found, state} =
      update_queued_message(state, message_id, fn qm ->
        # Preserve the original content wrapper so the message remains dispatchable
        updated_content =
          case {qm.content, new_content} do
            {{:inject_system_message, _old}, text} when is_binary(text) ->
              {:inject_system_message, text}

            _ ->
              new_content
          end

        %{qm | content: updated_content, status: :editing}
      end)

    if found do
      broadcast_queue_update(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reorder_queue, queue_type, ordered_ids}, _from, state) do
    queue_list =
      case queue_type do
        :priority -> state.priority_queue
        :pending -> state.pending_updates
      end

    id_map = Map.new(queue_list, fn qm -> {qm.id, qm} end)

    reordered =
      ordered_ids
      |> Enum.map(fn id -> Map.get(id_map, id) end)
      |> Enum.reject(&is_nil/1)

    # Append any messages not in ordered_ids (safety net)
    remaining_ids = MapSet.new(ordered_ids)

    leftover =
      Enum.reject(queue_list, fn qm -> MapSet.member?(remaining_ids, qm.id) end)

    state =
      case queue_type do
        :priority -> %{state | priority_queue: reordered ++ leftover}
        :pending -> %{state | pending_updates: reordered ++ leftover}
      end

    broadcast_queue_update(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:squash_queued, message_ids, opts}, _from, state) do
    id_set = MapSet.new(message_ids)

    {matched_priority, rest_priority} =
      Enum.split_with(state.priority_queue, fn qm -> MapSet.member?(id_set, qm.id) end)

    {matched_pending, rest_pending} =
      Enum.split_with(state.pending_updates, fn qm -> MapSet.member?(id_set, qm.id) end)

    all_matched = matched_priority ++ matched_pending

    if length(all_matched) < 2 do
      {:reply, {:error, :not_enough_messages}, state}
    else
      # Merge contents: user messages get concatenated, tuples get wrapped in a list
      squashed_content =
        case Keyword.get(opts, :content) do
          nil ->
            all_matched
            |> Enum.map(fn qm -> qm.content end)
            |> squash_contents()

          custom when is_binary(custom) ->
            {:inject_system_message, custom}
        end

      # Use the highest priority from the matched set
      highest_priority =
        all_matched
        |> Enum.map(fn qm -> qm.priority end)
        |> Enum.min_by(fn
          :urgent -> 0
          :high -> 1
          :normal -> 2
        end)

      squashed =
        QueuedMessage.new(squashed_content,
          priority: highest_priority,
          source: :user,
          metadata: %{squashed_from: Enum.map(all_matched, & &1.id)}
        )

      squashed = %{squashed | status: :squashed}

      # Place squashed message in the appropriate queue
      state =
        if highest_priority in [:urgent, :high] do
          %{state | priority_queue: rest_priority ++ [squashed], pending_updates: rest_pending}
        else
          %{state | priority_queue: rest_priority, pending_updates: rest_pending ++ [squashed]}
        end

      broadcast_queue_update(state)
      {:reply, {:ok, squashed.id}, state}
    end
  end

  @impl true
  def handle_call({:delete_queued, message_id}, _from, state) do
    orig_count =
      length(state.priority_queue) + length(state.pending_updates)

    priority_queue = Enum.reject(state.priority_queue, fn qm -> qm.id == message_id end)
    pending_updates = Enum.reject(state.pending_updates, fn qm -> qm.id == message_id end)

    new_count = length(priority_queue) + length(pending_updates)

    state = %{state | priority_queue: priority_queue, pending_updates: pending_updates}

    if new_count < orig_count do
      broadcast_queue_update(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:inject_guidance, text}, _from, state) do
    qm =
      QueuedMessage.new(
        {:inject_system_message, "[User Guidance]: #{text}"},
        priority: :high,
        source: :user,
        metadata: %{type: :guidance}
      )

    state = %{state | priority_queue: state.priority_queue ++ [qm]}
    broadcast_queue_update(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:force_pause, _from, %{status: :waiting_permission} = state) do
    cancelled =
      case state.pending_permission do
        nil ->
          nil

        p ->
          %{tool: p.tool_name, path: p.tool_path}
      end

    # Shut down the orphaned task before clearing it to prevent stale messages
    case state.loop_task do
      {%Task{} = task, _from} ->
        try do
          Task.shutdown(task, :brutal_kill)
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end

    paused_state = %{
      messages: state.messages,
      iteration: nil,
      reason: :force_paused,
      cancelled_permission: cancelled
    }

    state = %{
      state
      | pending_permission: nil,
        pause_queued: false,
        pause_requested: false,
        paused_state: paused_state,
        loop_task: nil
    }

    state = set_status_and_broadcast(state, :paused)
    {:reply, :ok, state}
  end

  def handle_call(:force_pause, _from, state) do
    {:reply, {:error, :not_waiting_permission}, state}
  end

  @impl true
  def handle_call({:resume, _opts}, _from, %{status: status} = state)
      when status != :paused do
    {:reply, {:error, :not_paused}, state}
  end

  def handle_call({:resume, opts}, _from, %{status: :paused} = state) do
    paused = state.paused_state

    if is_nil(paused) do
      Logger.warning("[Kin:data] paused_state is nil on resume for agent=#{state.name}")
      {:reply, {:error, :invalid_paused_state}, %{state | status: :idle}}
    else
      messages = paused.messages

      # If user provided steering guidance, inject it as a user message
      messages =
        case Keyword.get(opts, :guidance) do
          nil ->
            messages

          guidance when is_binary(guidance) ->
            messages ++ [%{role: :user, content: "[User Guidance]: #{guidance}"}]
        end

      state = %{
        state
        | pause_requested: false,
          paused_state: nil,
          messages: messages
      }

      state = set_status_and_broadcast(state, :working)

      loop_opts = build_loop_opts(state)
      snapshot = build_snapshot(state)

      task =
        Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
          run_loop_with_escalation(messages, loop_opts, snapshot)
        end)

      Logger.debug("[Kin:loop] spawned agent=#{state.name} ref=#{inspect(task.ref)}")

      {:reply, :ok, %{state | loop_task: {task, nil}}}
    end
  end

  # --- AskUser rate-limit handle_call ---

  @impl true
  def handle_call({:check_ask_user_rate_limit, _tool_args}, _from, state) do
    cond do
      state.pending_ask_user != nil ->
        {:reply, {:batch, state.pending_ask_user.card_id}, state}

      state.last_asked_at != nil and
          System.monotonic_time(:millisecond) - state.last_asked_at < 300_000 ->
        {:reply, :drop, state}

      true ->
        card_id = Ecto.UUID.generate()
        new_pending = %{card_id: card_id, questions: []}
        state = %{state | pending_ask_user: new_pending}
        state = set_status_and_broadcast(state, :ask_user_pending)
        {:reply, :allow, state}
    end
  end

  @impl true
  def handle_call({:ask_user_answered, question_id}, _from, state) do
    new_pending =
      case state.pending_ask_user do
        nil ->
          nil

        %{questions: questions} = card ->
          remaining = Enum.reject(questions, &(&1.question_id == question_id))
          %{card | questions: remaining}
      end

    state =
      if new_pending == nil or new_pending.questions == [] do
        state =
          %{state | pending_ask_user: nil, last_asked_at: System.monotonic_time(:millisecond)}

        set_status_and_broadcast(state, :idle)
      else
        %{state | pending_ask_user: new_pending}
      end

    {:reply, :ok, state}
  end

  # --- Spawn gate handle_calls ---

  @impl true
  def handle_call(:get_spawn_settings, _from, state) do
    {:reply, %{auto_approve_spawns: state.auto_approve_spawns}, state}
  end

  def handle_call({:set_auto_approve_spawns, enabled}, _from, state) do
    {:reply, :ok, %{state | auto_approve_spawns: enabled}}
  end

  def handle_call(:is_gate_open?, _from, state) do
    {:reply, state.status == :approval_pending, state}
  end

  def handle_call({:check_spawn_budget, estimated_cost}, _from, state) do
    budget_limit =
      case state.role_config do
        %{budget_limit: limit} when is_number(limit) -> limit / 1
        _ -> 5.0
      end

    summary = CostTracker.team_cost_summary(state.team_id)

    spent =
      case summary[:total_cost_usd] do
        %Decimal{} = d -> Decimal.to_float(d)
        n when is_number(n) -> n / 1
        _ -> 0.0
      end

    remaining = budget_limit - spent

    if remaining < estimated_cost do
      {:reply, {:budget_exceeded, %{remaining: remaining, estimated: estimated_cost}}, state}
    else
      {:reply, :ok, state}
    end
  end

  # --- handle_cast ---

  @impl true
  def handle_cast(:request_pause, %{status: :idle} = state) do
    # No-op: agent is not running, nothing to pause
    {:noreply, state}
  end

  def handle_cast(:request_pause, %{status: :waiting_permission} = state) do
    # Queue the pause instead of setting pause_requested -- permission must resolve first
    broadcast_team(state, {:agent_pause_queued, state.name})
    {:noreply, %{state | pause_queued: true}}
  end

  def handle_cast(:request_pause, %{status: :approval_pending} = state) do
    # Pre-wire for Phase 6: queue pause during approval gate
    broadcast_team(state, {:agent_pause_queued, state.name})
    {:noreply, %{state | pause_queued: true}}
  end

  def handle_cast(:request_pause, %{status: :ask_user_pending} = state) do
    # Queue pause during ask_user gate — same pattern as approval_pending
    broadcast_team(state, {:agent_pause_queued, state.name})
    {:noreply, %{state | pause_queued: true}}
  end

  def handle_cast(:request_pause, %{status: :awaiting_synthesis} = state) do
    # Queue pause during research synthesis — same pattern as approval_pending and ask_user_pending
    broadcast_team(state, {:agent_pause_queued, state.name})
    {:noreply, %{state | pause_queued: true}}
  end

  def handle_cast(:request_pause, state) do
    {:noreply, %{state | pause_requested: true}}
  end

  @impl true
  def handle_cast({:open_spawn_gate, _gate_id, _pending_info}, state) do
    # Mark agent approval_pending so the UI can show the gate.
    # The tool task process holds the receive block; this cast just updates status.
    state = set_status_and_broadcast(state, :approval_pending)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:close_spawn_gate, state) do
    # Clear approval_pending status after the spawn gate resolves (approved, denied, or timed out).
    # This allows the agent to retry team_spawn within the same loop if the spawn fails.
    state =
      if state.status == :approval_pending do
        set_status_and_broadcast(state, :working)
      else
        state
      end

    state = maybe_apply_queued_pause(state, state.messages)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:enter_awaiting_synthesis, _researcher_count}, state) do
    state = set_status_and_broadcast(state, :awaiting_synthesis)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:exit_awaiting_synthesis, state) do
    state = set_status_and_broadcast(state, :working)
    # Drain any pause that was queued while awaiting synthesis
    state = maybe_apply_queued_pause(state, [])
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:append_ask_user_question, tool_args, card_id, question_id, tool_task_pid},
        state
      ) do
    question_text = Map.get(tool_args, "question") || Map.get(tool_args, :question)
    options = Map.get(tool_args, "options") || Map.get(tool_args, :options) || []

    question_entry = %{question_id: question_id, question: question_text, options: options}

    new_pending =
      case state.pending_ask_user do
        %{card_id: ^card_id} = card ->
          %{card | questions: card.questions ++ [question_entry]}

        _ ->
          # Card was closed between check and append — create a fresh entry
          %{card_id: card_id, questions: [question_entry]}
      end

    # Register the tool task pid in Registry so the answer can be routed back to the
    # tool task process that is blocking on receive {:ask_user_answer, question_id, _}
    Registry.register(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}, tool_task_pid)

    # Publish a question signal so WorkspaceLive can render it in the ask-user card
    signal =
      Loomkin.Signals.Team.AskUserQuestion.new!(%{
        question_id: question_id,
        agent_name: state.name,
        team_id: state.team_id,
        question: question_text || ""
      })

    Loomkin.Signals.publish(%{signal | data: Map.put(signal.data, :options, options)})

    {:noreply, %{state | pending_ask_user: new_pending}}
  end

  # Queue task assignments while agent is suspended for healing
  @impl true
  def handle_cast({:assign_task, task}, %{status: :suspended_healing} = state) do
    Logger.info(
      "[Kin:agent] #{state.name} queuing task during healing suspension task=#{inspect(task[:id])}"
    )

    qm = QueuedMessage.new({:assign_task, task}, priority: :high, source: :system)
    {:noreply, %{state | healing_queue: state.healing_queue ++ [qm]}}
  end

  @impl true
  def handle_cast({:assign_task, task}, state) do
    # Only override model if the task has an explicit model_hint;
    # otherwise preserve the agent's current model (set at spawn from user's selection)
    model = if task[:model_hint], do: ModelRouter.select(state.role, task), else: state.model
    state = %{state | task: task, model: model}

    # Detect scope tier from task description
    description = task[:title] || task[:description] || ""

    {:ok, tier, _estimate} =
      ScopeDetector.detect_tier(%{task_description: description})

    state = %{state | scope_tier: tier, files_touched: MapSet.new(), task_cost_usd: 0.0}

    # Cache the task so the rebalancer can track what this agent is working on
    if task[:id] do
      Context.cache_task(state.team_id, task[:id], %{
        title: task[:title] || task[:description] || "assigned task",
        status: :assigned,
        owner: state.name
      })
    end

    messages = maybe_prefetch_context(state, task)

    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_cast({:update_project_path, new_path}, state) do
    {:noreply, %{state | project_path: new_path}}
  end

  @impl true
  def handle_cast({:update_model, new_model}, state) do
    {:noreply, %{state | model: new_model}}
  end

  # --- Healing wake handler ---

  @impl true
  def handle_cast({:wake_from_healing, healing_summary}, %{status: :suspended_healing} = state) do
    Logger.info("[Kin:agent] #{state.name} waking from healing team=#{state.team_id}")

    summary_msg = %{
      role: :system,
      content: """
      [Healing complete] #{healing_summary[:description] || "Error resolved"}
      Root cause: #{healing_summary[:root_cause] || "Unknown"}
      Fix applied: #{healing_summary[:fix_description] || "Applied automatically"}
      Continue your previous task.
      """
    }

    restored_messages = state.frozen_state.messages ++ [summary_msg]

    state = %{
      state
      | messages: restored_messages,
        frozen_state: nil,
        failure_count: 0
    }

    state = set_status_and_broadcast(state, :idle)

    # Publish healing complete signal
    try do
      Loomkin.Signals.Agent.HealingComplete.new!(%{
        agent_name: to_string(state.name),
        team_id: state.team_id,
        healing_summary: healing_summary
      })
      |> Loomkin.Signals.publish()
    rescue
      _ -> :ok
    end

    # Drain any messages queued during healing, then re-run the agent loop
    state = drain_healing_queue(state)
    state = maybe_rerun_after_healing(state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:wake_from_healing, _healing_summary}, state) do
    # Not suspended — no-op
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:peer_message, from, content},
        %{status: :awaiting_synthesis, name: name, team_id: team_id} = state
      ) do
    # Route peer_message to the registered tool task (blocking in collect_research_findings)
    # instead of appending to the agent's message history.
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:awaiting_synthesis, team_id, name}) do
      [{tool_task_pid, _}] ->
        send(tool_task_pid, {:research_findings, from, content})

      [] ->
        # Fallback: no tool task registered yet; discard (will not deadlock)
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    state = %{state | messages: state.messages ++ [peer_msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_cast({:permission_response, action, tool_name, tool_path}, state) do
    case state.pending_permission do
      nil ->
        {:noreply, state}

      pending_info ->
        if action == "allow_always" do
          # Store grant with the actual resolved path, not wildcard
          Loomkin.Permissions.Manager.grant(to_string(tool_name), tool_path, state.session_id)
        end

        if state.pause_queued do
          # Pause was queued while waiting for permission -- transition to paused
          denial_context =
            if action not in ["allow_once", "allow_always"] do
              %{denied_tool: tool_name, denied_path: tool_path}
            else
              nil
            end

          paused_state = %{
            messages: state.messages,
            iteration: nil,
            reason: :user_requested,
            cancelled_permission: denial_context
          }

          state = %{
            state
            | pending_permission: nil,
              pause_queued: false,
              paused_state: paused_state
          }

          state = set_status_and_broadcast(state, :paused)
          {:noreply, state}
        else
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
  end

  # --- Async loop result handlers ---

  @impl true
  def handle_info(
        {ref, {:loop_ok, text, msgs, meta}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task
    task_id = state.task && state.task[:id]

    if task_id,
      do: ModelRouter.record_success(state.team_id, state.name, task_id, state.model)

    # Mark cached task as completed and clear agent task
    if task_id do
      Context.cache_task(state.team_id, task_id, %{
        title: (state.task && state.task[:title]) || "completed",
        status: :completed,
        owner: state.name
      })
    end

    state = %{state | messages: msgs, failure_count: 0, loop_task: nil, task: nil}
    state = track_usage(state, meta)

    state = set_status_and_broadcast(state, :idle)

    if from do
      GenServer.reply(from, {:ok, text})
    else
      if task_id, do: Loomkin.Teams.Tasks.complete_task(task_id, text)
    end

    {:noreply, drain_queues(maybe_apply_queued_pause(state, msgs))}
  end

  @impl true
  def handle_info(
        {ref, {:loop_ok_escalated, text, msgs, meta, new_model}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task
    task_id = state.task && state.task[:id]
    if task_id, do: ModelRouter.record_success(state.team_id, state.name, task_id, new_model)

    if task_id do
      Context.cache_task(state.team_id, task_id, %{
        title: (state.task && state.task[:title]) || "completed",
        status: :completed,
        owner: state.name
      })
    end

    state =
      %{state | messages: msgs, failure_count: 0, model: new_model, loop_task: nil, task: nil}

    state = track_usage(state, meta)

    state = set_status_and_broadcast(state, :idle)

    if from do
      GenServer.reply(from, {:ok, text})
    else
      if task_id, do: Loomkin.Teams.Tasks.complete_task(task_id, text)
    end

    {:noreply, drain_queues(maybe_apply_queued_pause(state, msgs))}
  end

  # --- Healing suspension handler ---

  @impl true
  def handle_info(
        {ref, {:loop_healing_needed, classification, msgs}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task

    Logger.info(
      "[Kin:agent] #{state.name} suspending for healing category=#{classification.category} team=#{state.team_id}"
    )

    frozen_state = %{
      messages: msgs,
      task: state.task
    }

    state = %{
      state
      | messages: msgs,
        loop_task: nil,
        frozen_state: frozen_state
    }

    state = set_status_and_broadcast(state, :suspended_healing)

    # Reply to caller if this was a synchronous send_message
    if from, do: GenServer.reply(from, {:ok, :suspended_healing})

    # Publish healing requested signal for UI
    try do
      Loomkin.Signals.Agent.HealingRequested.new!(%{
        agent_name: to_string(state.name),
        team_id: state.team_id,
        classification: classification,
        error_context: classification[:error_context] || %{}
      })
      |> Loomkin.Signals.publish()
    rescue
      _ -> :ok
    end

    # Trigger the orchestrator to start healing (S1 fix)
    healing_policy = state.role_config.healing_policy

    healing_context = %{
      classification: classification,
      error_context: classification[:error_context] || %{},
      budget_usd: healing_policy[:budget_usd] || 0.50,
      timeout_ms: healing_policy[:timeout_ms] || :timer.minutes(5),
      max_attempts: healing_policy[:max_attempts] || 2
    }

    try do
      case Loomkin.Healing.Orchestrator.request_healing(
             state.team_id,
             state.name,
             healing_context
           ) do
        {:ok, session_id} ->
          Logger.info("[Kin:agent] #{state.name} healing session started id=#{session_id}")

        {:error, reason} ->
          Logger.warning("[Kin:agent] #{state.name} failed to start healing: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning(
          "[Kin:agent] #{state.name} healing orchestrator unavailable: #{inspect(e)}"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {ref, {:loop_error, reason, msgs}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task
    task_id = state.task && state.task[:id]

    require Logger

    Logger.error(
      "[Kin:agent] loop error name=#{state.name} team=#{state.team_id} reason=#{inspect(reason)}"
    )

    if task_id do
      Context.cache_task(state.team_id, task_id, %{
        title: (state.task && state.task[:title]) || "failed",
        status: :failed,
        owner: state.name
      })
    end

    state = %{state | messages: msgs, loop_task: nil, pending_permission: nil}
    state = set_status_and_broadcast(state, :idle)

    if from do
      GenServer.reply(from, {:error, reason})
    else
      if task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, inspect(reason))
    end

    {:noreply, drain_queues(maybe_apply_queued_pause(state, msgs))}
  end

  @impl true
  def handle_info(
        {ref, {:loop_pending, pending_info, msgs}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task
    state = %{state | messages: msgs, pending_permission: pending_info, loop_task: nil}
    state = set_status(state, :waiting_permission)

    if from, do: GenServer.reply(from, {:ok, :pending_permission})

    {:noreply, drain_queues(state)}
  end

  @impl true
  def handle_info(
        {ref, {:loop_paused, reason, msgs, iteration}},
        %{loop_task: {%Task{ref: task_ref}, _from}} = state
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {%Task{}, from} = state.loop_task

    paused_state = %{
      messages: msgs,
      iteration: iteration,
      reason: reason
    }

    state = %{
      state
      | messages: msgs,
        loop_task: nil,
        pause_requested: false,
        paused_state: paused_state
    }

    state = set_status_and_broadcast(state, :paused)

    if from, do: GenServer.reply(from, {:ok, :paused})

    {:noreply, drain_queues(state)}
  end

  # Fallthrough for unrecognized Task refs (e.g. from stale or external tasks)
  @impl true
  def handle_info({ref, _msg}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case state.loop_task do
      {%Task{ref: ^ref}, from} ->
        task_id = state.task && state.task[:id]

        require Logger

        Logger.error(
          "[Kin:agent] loop crashed name=#{state.name} team=#{state.team_id} reason=#{inspect(reason)}"
        )

        if task_id do
          Context.cache_task(state.team_id, task_id, %{
            title: (state.task && state.task[:title]) || "crashed",
            status: :failed,
            owner: state.name
          })
        end

        state = %{state | loop_task: nil, pending_permission: nil}

        status =
          if reason in [:normal, :shutdown] do
            :idle
          else
            :error
          end

        state = set_status_and_broadcast(state, status)

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

  # Signals must be dispatched even during active loops (not queued as raw tuples).
  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, %{loop_task: {_task, _from}} = state) do
    if signal_for_this_team?(sig, state) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, %{loop_task: {_task, _from}} = state) when is_tuple(msg) do
    case PriorityRouter.classify(msg) do
      {:urgent, _type} ->
        handle_urgent(msg, state)

      {:high, _type} ->
        qm = QueuedMessage.new(msg, priority: :high, source: :system)
        state = %{state | priority_queue: state.priority_queue ++ [qm]}
        broadcast_queue_update(state)
        {:noreply, state}

      {:normal, _type} ->
        qm = QueuedMessage.new(msg, priority: :normal, source: :system)
        state = %{state | pending_updates: state.pending_updates ++ [qm]}
        broadcast_queue_update(state)
        {:noreply, state}

      {:ignore, _type} ->
        {:noreply, state}
    end
  end

  # --- Signal Bus dispatch (converts signals to tuples for existing handlers) ---

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    if signal_for_this_team?(sig, state) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "context.update"} = sig, state) do
    from = sig.data[:from] || sig.data["from"]
    payload = sig.data[:payload] || sig.data

    if is_nil(from) do
      Logger.warning(
        "[Kin:data] context.update signal missing :from, keys=#{inspect(Map.keys(sig.data))}"
      )
    end

    handle_info({:context_update, from, payload}, state)
  end

  def handle_info(%Jido.Signal{type: "agent.status"} = sig, state) do
    case sig.data do
      %{agent_name: name, status: status} when not is_nil(name) and not is_nil(status) ->
        handle_info({:agent_status, name, status}, state)

      _ ->
        Logger.warning(
          "[Kin:data] agent.status signal missing fields: #{inspect(sig.data, limit: 100)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "agent.role.changed"} = sig, state) do
    case sig.data do
      %{agent_name: name, old_role: old_role, new_role: new_role}
      when not is_nil(name) and not is_nil(new_role) ->
        handle_info({:role_changed, name, old_role, new_role}, state)

      _ ->
        Logger.warning(
          "[Kin:data] role.changed signal missing fields: #{inspect(sig.data, limit: 100)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "context.keeper.created"} = sig, state) do
    handle_info({:keeper_created, sig.data}, state)
  end

  def handle_info(%Jido.Signal{type: "collaboration.peer.message"} = sig, state) do
    # Skip messages targeted at a different agent (unless lead/concierge for oversight)
    target = sig.data[:target]

    if target && target != to_string(state.name) && state.role not in [:lead, :concierge] do
      {:noreply, state}
    else
      handle_peer_message_signal(sig, state)
    end
  end

  def handle_info(%Jido.Signal{type: "team.task.assigned"} = sig, state) do
    case sig.data do
      %{task_id: task_id, agent_name: name} when not is_nil(task_id) and not is_nil(name) ->
        handle_info({:task_assigned, task_id, name}, state)

      _ ->
        Logger.warning(
          "[Kin:data] task.assigned signal missing fields: #{inspect(sig.data, limit: 100)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.task.ready_for_review"} = sig, state) do
    handle_info(
      {:task_ready_for_review, sig.data.task_id, sig.data.owner, sig.data[:summary]},
      state
    )
  end

  def handle_info(%Jido.Signal{type: "team.task.blocked"} = sig, state) do
    handle_info({:task_blocked, sig.data.task_id, sig.data.owner, sig.data[:reason]}, state)
  end

  def handle_info(%Jido.Signal{type: "team.task.partially_complete"} = sig, state) do
    handle_info(
      {:task_partially_complete, sig.data.task_id, sig.data.owner, sig.data[:partial_result]},
      state
    )
  end

  def handle_info(%Jido.Signal{type: "team.rendezvous." <> _}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "agent.ready"}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "team.task.completed"} = sig, state) do
    signal_team_id = sig.data[:team_id]

    is_from_child_team =
      signal_team_id != nil and signal_team_id != state.team_id and
        signal_team_id in Loomkin.Teams.Manager.get_child_teams(state.team_id)

    if is_from_child_team and state.role in [:lead, :concierge] do
      handle_info({:child_team_task_completed, sig.data}, state)
    else
      handle_info({:sub_team_completed, sig.data[:sub_team_id] || sig.data[:task_id]}, state)
    end
  end

  def handle_info(%Jido.Signal{type: "team.task.started"} = sig, state) do
    handle_info({:tasks_unblocked, [sig.data.task_id]}, state)
  end

  def handle_info(%Jido.Signal{type: "team.task.milestone"} = sig, state) do
    handle_info(
      {:task_milestone, sig.data.task_id, sig.data.owner, sig.data.milestone_name},
      state
    )
  end

  def handle_info(%Jido.Signal{type: "team.task.priority_changed"} = sig, state) do
    handle_info(
      {:task_priority_changed, sig.data.task_id, sig.data.owner, sig.data.new_priority},
      state
    )
  end

  def handle_info(%Jido.Signal{type: "collaboration.vote.response"} = sig, state) do
    handle_info({:vote_request, sig.data.vote_id, nil, nil, nil}, state)
  end

  def handle_info(%Jido.Signal{type: "collaboration.debate.response"} = sig, state) do
    handle_info({:debate_start, sig.data.debate_id, nil, []}, state)
  end

  def handle_info(%Jido.Signal{type: "decision.logged"} = sig, state) do
    handle_info({:discovery_relevant, sig.data}, state)
  end

  def handle_info(%Jido.Signal{type: "context.discovery.relevant"} = sig, state) do
    handle_info({:discovery_relevant, sig.data}, state)
  end

  def handle_info(%Jido.Signal{type: "collaboration.pair.event"} = sig, state) do
    msg = sig.data
    name = to_string(state.name)

    cond do
      msg[:coder] == name or msg[:reviewer] == name ->
        handle_info({:pair_broadcast, msg[:from], msg[:event], msg[:payload] || %{}}, state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "collaboration.conversation.ended"} = sig, state) do
    spawned_by = sig.data[:spawned_by]
    agent_name = to_string(state.name)

    if spawned_by == agent_name do
      summary = sig.data[:summary] || %{}
      conversation_id = sig.data[:conversation_id]
      topic = summary[:topic] || "unknown"

      synthesis_text = format_conversation_synthesis(summary, conversation_id, topic)

      synthesis_msg = %{
        role: :user,
        content: "[Conversation synthesis]: #{synthesis_text}"
      }

      state = %{state | messages: state.messages ++ [synthesis_msg]}
      {:noreply, maybe_wake_idle(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "team.dissolved"}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "team.child.created"}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "team.permission.request"}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "team.ask_user." <> _}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "channel." <> _}, state) do
    {:noreply, state}
  end

  # UI streaming signals — agents don't need these
  def handle_info(%Jido.Signal{type: "agent.stream." <> _}, state) do
    {:noreply, state}
  end

  # Track file writes/edits for scope gate enforcement
  def handle_info(
        %Jido.Signal{
          type: "agent.tool.executing",
          data: %{agent_name: agent_name, payload: %{tool_name: tool, tool_target: file_path}}
        },
        state
      )
      when tool in ["file_write", "file_edit"] do
    if to_string(agent_name) == to_string(state.name) and is_binary(file_path) and
         file_path != "*" do
      {:noreply, %{state | files_touched: MapSet.put(state.files_touched, file_path)}}
    else
      {:noreply, state}
    end
  end

  # Tool lifecycle signals — log starts and errors for visibility
  def handle_info(%Jido.Signal{type: "agent.tool." <> action} = sig, state) do
    if action in ["start", "error"] do
      agent = sig.data[:agent_name] || "unknown"
      tool = sig.data[:tool_name] || "unknown"
      Logger.debug("[Kin:signal] tool.#{action} agent=#{agent} tool=#{tool}")
    end

    {:noreply, state}
  end

  # Usage signals — already tracked via telemetry
  def handle_info(%Jido.Signal{type: "agent.usage"}, state) do
    {:noreply, state}
  end

  # Queue bookkeeping — internal only
  def handle_info(%Jido.Signal{type: "agent.queue.updated"}, state) do
    {:noreply, state}
  end

  # Agent errors — log at warning level for visibility
  def handle_info(%Jido.Signal{type: "agent.error"} = sig, state) do
    agent = sig.data[:agent_name] || "unknown"
    reason = sig.data[:reason] || sig.data[:error] || "unknown"

    Logger.warning(
      "[Kin:signal] agent.error agent=#{agent} reason=#{inspect(reason, limit: 200)}"
    )

    {:noreply, state}
  end

  # Escalation signals — log model transitions
  def handle_info(%Jido.Signal{type: "agent.escalation"} = sig, state) do
    agent = sig.data[:agent_name] || "unknown"
    from_model = sig.data[:from_model] || "unknown"
    to_model = sig.data[:to_model] || "unknown"
    Logger.info("[Kin:signal] escalation agent=#{agent} #{from_model} -> #{to_model}")
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: _type}, state) do
    {:noreply, state}
  end

  # --- handle_info for PubSub (idle path) ---

  @impl true
  def handle_info({:context_update, from, payload}, state) do
    context = Map.put(state.context, from, payload)
    {:noreply, %{state | context: context}}
  end

  @impl true
  def handle_info({:agent_status, _agent_name, _status}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:keeper_created, info}, state) do
    if info.source == to_string(state.name) do
      {:noreply, state}
    else
      keeper_msg = %{
        role: :system,
        content:
          "New keeper available: [#{info.id}] \"#{info.topic}\" by #{info.source} (#{info.tokens} tokens)"
      }

      {:noreply, %{state | messages: state.messages ++ [keeper_msg]}}
    end
  end

  @impl true
  def handle_info({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    state = %{state | messages: state.messages ++ [peer_msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:task_assigned, task_id, agent_name}, state) do
    if to_string(agent_name) == to_string(state.name) do
      case Loomkin.Teams.Tasks.get_task(task_id) do
        {:ok, task} ->
          # Only override model if the task has an explicit model_hint;
          # otherwise preserve the agent's current model (set at spawn from user's selection)
          task_map = %{
            id: task.id,
            description: task.description,
            title: task.title,
            model_hint: task.model_hint
          }

          model =
            if task.model_hint, do: ModelRouter.select(state.role, task_map), else: state.model

          state = %{state | task: task_map, model: model}
          messages = maybe_prefetch_context(state, state.task)
          state = %{state | messages: messages}

          if state.status == :idle do
            send(self(), {:auto_execute_task, task_id})
          end

          {:noreply, state}

        {:error, _} ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:auto_execute_task, task_id}, state) do
    if state.status != :idle || state.loop_task != nil do
      {:noreply, state}
    else
      task = state.task

      if is_nil(task) do
        Logger.warning(
          "[Kin:data] auto_execute_task with nil task for agent=#{state.name} task_id=#{task_id}"
        )
      end

      description =
        (is_map(task) && (task[:description] || task[:title])) || "Complete task #{task_id}"

      state = set_status_and_broadcast(state, :working)

      user_message = %{role: :user, content: description}
      messages = state.messages ++ [user_message]
      loop_opts = build_loop_opts(state)
      snapshot = build_snapshot(state)

      async_task =
        Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
          run_loop_with_escalation(messages, loop_opts, snapshot)
        end)

      Logger.debug("[Kin:loop] spawned agent=#{state.name} ref=#{inspect(async_task.ref)}")

      {:noreply, %{state | loop_task: {async_task, nil}}}
    end
  end

  # Wake-up handler: when an idle agent accumulates messages (peer messages, queries,
  # task notifications), this starts a new loop so the agent processes them.
  @impl true
  def handle_info(:wake_up, state) do
    state = %{state | wake_ref: nil}

    if state.status != :idle || state.loop_task != nil do
      {:noreply, state}
    else
      # Nothing to process — stay idle
      if state.messages == [] do
        {:noreply, state}
      else
        Logger.info(
          "[Kin:agent] waking idle agent=#{state.name} with #{length(state.messages)} accumulated messages"
        )

        # Create a synthetic task for tracking
        task_id = "wake_#{state.team_id}_#{state.name}_#{System.unique_integer([:positive])}"
        title = "Process incoming messages"

        Context.cache_task(state.team_id, task_id, %{
          title: title,
          status: :in_progress,
          owner: state.name
        })

        state = %{state | task: %{id: task_id, title: title}}
        state = set_status_and_broadcast(state, :working)

        messages = state.messages
        loop_opts = build_loop_opts(state)
        snapshot = build_snapshot(state)

        async_task =
          Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
            run_loop_with_escalation(messages, loop_opts, snapshot)
          end)

        Logger.debug("[Kin:loop] wake spawned agent=#{state.name} ref=#{inspect(async_task.ref)}")

        {:noreply, %{state | loop_task: {async_task, nil}}}
      end
    end
  end

  @impl true
  def handle_info({:query, query_id, from, question, enrichments}, state) do
    # Don't process our own broadcast questions — but allow cross-team queries
    # even when agent names match (e.g., two "lead" agents in sibling teams)
    same_name? = from == to_string(state.name)

    same_team? =
      case enrichments do
        %{source_team: source_team} -> source_team == state.team_id
        _ -> true
      end

    if same_name? and same_team? do
      {:noreply, state}
    else
      # enrichments can be a list (intra-team) or a map with :source_team (cross-team)
      {enrichment_text, source_label} =
        case enrichments do
          %{source_team: source_team} ->
            {"", " (cross-team from #{source_team})"}

          [] ->
            {"", ""}

          list when is_list(list) ->
            {"\n\nRelevant context:\n" <> Enum.join(list, "\n"), ""}
        end

      query_msg = %{
        role: :user,
        content: """
        [Query from #{from}#{source_label} | ID: #{query_id}]
        #{question}#{enrichment_text}

        You can respond using peer_answer_question with query_id "#{query_id}", \
        or forward the question to another agent if someone else is better suited to answer.\
        """
      }

      state = %{state | messages: state.messages ++ [query_msg]}
      {:noreply, maybe_wake_idle(state)}
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

    state = %{state | messages: state.messages ++ [answer_msg]}
    {:noreply, maybe_wake_idle(state)}
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
        _ ->
          ""
      end

    summary = if results != "", do: "\nResults:\n#{results}", else: ""

    msg = %{
      role: :system,
      content: "[System] Sub-team #{sub_team_id} completed and dissolved.#{summary}"
    }

    {:noreply, maybe_wake_idle(%{state | messages: state.messages ++ [msg]})}
  end

  @impl true
  def handle_info({:child_team_task_completed, signal_data}, state) do
    task_id = signal_data[:task_id]
    owner = signal_data[:owner] || "unknown"
    child_team_id = signal_data[:team_id] || "unknown"

    # Fetch the full task from DB to get structured result fields
    structured_result =
      try do
        case Loomkin.Teams.Tasks.get_task(task_id) do
          {:ok, task} ->
            format_child_task_result(task, owner, child_team_id)

          {:error, _} ->
            result = signal_data[:result] || ""

            "[Sub-team result] Agent #{owner} in child team #{child_team_id} completed task #{task_id}.\nResult: #{result}"
        end
      rescue
        e ->
          Logger.warning("[Kin:agent] Failed to fetch child team task #{task_id}: #{inspect(e)}")

          "[Sub-team result] Agent #{owner} in child team #{child_team_id} completed task #{task_id}."
      end

    msg = %{role: :user, content: structured_result}
    state = %{state | messages: state.messages ++ [msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:role_changed, _agent_name, _old_role, _new_role}, state) do
    {:noreply, state}
  end

  # --- Debate protocol handlers ---

  @impl true
  def handle_info({:debate_start, debate_id, topic, participants}, state) do
    # Debate signals are already received via collaboration.peer.message subscription

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
    # Pair signals are already received via collaboration.peer.message subscription

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

    state = %{
      state
      | messages: messages,
        failure_count: 0,
        loop_task: nil,
        task: nil,
        pending_permission: nil
    }

    state = track_usage(state, metadata)
    state = set_status_and_broadcast(state, :idle)

    # If there's an active task, complete it with the response
    if task_id do
      Loomkin.Teams.Tasks.complete_task(task_id, response_text)
    end

    {:noreply, drain_queues(state)}
  end

  @impl true
  def handle_info({:loop_resumed, {:error, _reason, messages}}, state) do
    state = %{state | messages: messages, loop_task: nil, task: nil, pending_permission: nil}
    state = set_status_and_broadcast(state, :idle)
    {:noreply, drain_queues(state)}
  end

  @impl true
  def handle_info({:loop_resumed, {:pending_permission, new_pending, messages}}, state) do
    state = %{state | messages: messages, pending_permission: new_pending}
    state = set_status(state, :waiting_permission)
    {:noreply, drain_queues(state)}
  end

  @impl true
  def handle_info({:loop_resumed, {:paused, reason, messages, iteration}}, state) do
    paused_state = %{messages: messages, iteration: iteration, reason: reason}

    state = %{
      state
      | messages: messages,
        pause_requested: false,
        paused_state: paused_state,
        pending_permission: nil
    }

    state = set_status_and_broadcast(state, :paused)
    {:noreply, drain_queues(state)}
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

    state = %{state | messages: state.messages ++ [review_msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:task_ready_for_review, task_id, owner, summary}, state) do
    msg = %{
      role: :system,
      content:
        "[System] Task #{task_id} by #{owner} is ready for review. Summary: #{summary || "none"}"
    }

    state = %{state | messages: state.messages ++ [msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:task_blocked, task_id, owner, reason}, state) do
    msg = %{
      role: :system,
      content: "[System] Task #{task_id} by #{owner} is blocked. Reason: #{reason || "unknown"}"
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:task_partially_complete, task_id, owner, partial_result}, state) do
    msg = %{
      role: :system,
      content:
        "[System] Task #{task_id} by #{owner} is partially complete. " <>
          "Partial result: #{String.slice(partial_result || "", 0, 200)}"
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:tasks_unblocked, task_ids}, state) do
    handle_info({:tasks_unblocked, task_ids, %{}}, state)
  end

  @impl true
  def handle_info({:tasks_unblocked, task_ids, predecessor_outputs}, state) do
    output_context =
      predecessor_outputs
      |> Enum.map(fn {task_id, outputs} ->
        output_lines =
          outputs
          |> Enum.map(&format_predecessor_output/1)
          |> Enum.join("\n\n")

        "Task #{task_id} predecessor work:\n#{output_lines}"
      end)
      |> Enum.join("\n\n")

    base_content =
      "[System] Tasks now available: #{Enum.join(task_ids, ", ")}. Use team_progress to see details."

    content =
      if output_context == "" do
        base_content
      else
        base_content <> "\n\nPredecessor work summary:\n" <> output_context
      end

    msg = %{role: :system, content: content}

    state = %{state | messages: state.messages ++ [msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:task_milestone, _task_id, owner, milestone_name}, state) do
    msg = %{
      role: :system,
      content:
        "[System] Agent #{owner} reached milestone '#{milestone_name}'. " <>
          "Dependent tasks may now be unblocked."
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:task_priority_changed, task_id, _owner, new_priority}, state) do
    msg = %{
      role: :system,
      content: "[System] Task #{task_id} priority changed to #{new_priority}."
    }

    {:noreply, %{state | messages: state.messages ++ [msg]}}
  end

  @impl true
  def handle_info({:role_change_request, _agent_name, _old_role, _new_role, _request_id}, state) do
    {:noreply, state}
  end

  # --- Nervous system handlers ---

  @impl true
  def handle_info({:discovery_relevant, payload}, state) do
    %{
      observation_title: obs_title,
      goal_title: goal_title,
      source_agent: source,
      keeper_id: keeper_id
    } = payload

    msg = "[Discovery from #{source}] #{obs_title} — relevant to your goal: #{goal_title}"

    msg =
      if keeper_id,
        do: msg <> "\n  → Full context: context_retrieve on keeper #{keeper_id}",
        else: msg

    messages = state.messages ++ [%{role: :user, content: msg}]
    state = %{state | messages: messages}
    {:noreply, maybe_wake_idle(state)}
  end

  @impl true
  def handle_info({:confidence_warning, payload}, state) do
    %{
      source_title: title,
      source_confidence: conf,
      affected_title: affected,
      keeper_id: keeper_id
    } = payload

    msg =
      "[Confidence Warning] Upstream decision '#{title}' has low confidence (#{conf}). Your work on '#{affected}' may be affected."

    msg = if keeper_id, do: msg <> "\n  → Re-evaluate using keeper #{keeper_id}", else: msg

    messages = state.messages ++ [%{role: :user, content: msg}]
    state = %{state | messages: messages}
    {:noreply, maybe_wake_idle(state)}
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
    state = %{state | messages: state.messages ++ [msg]}
    {:noreply, maybe_wake_idle(state)}
  end

  def handle_info({:child_team_spawned, child_team_id}, state) do
    updated =
      if child_team_id in state.spawned_child_teams do
        state.spawned_child_teams
      else
        [child_team_id | state.spawned_child_teams]
      end

    {:noreply, %{state | spawned_child_teams: updated}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  # If a pause was queued during an approval gate, apply it now that the gate has resolved.
  defp maybe_apply_queued_pause(%{pause_queued: true} = state, msgs) do
    paused_state = %{
      messages: msgs,
      iteration: nil,
      reason: :user_requested,
      cancelled_permission: nil
    }

    state = %{state | pause_queued: false, pause_requested: false, paused_state: paused_state}
    set_status_and_broadcast(state, :paused)
  end

  defp maybe_apply_queued_pause(state, _msgs), do: state

  defp do_change_role(state, new_role, role_config_override) do
    role_result =
      case role_config_override do
        %Role{} = config -> {:ok, config}
        _ -> Role.get(new_role)
      end

    case role_result do
      {:ok, role_config} ->
        old_role = state.role
        effective_role_name = role_config.name || new_role

        state = %{
          state
          | role: effective_role_name,
            role_config: role_config,
            tools: role_config.tools
        }

        # Update Registry metadata
        Registry.update_value(Loomkin.Teams.AgentRegistry, {state.team_id, state.name}, fn _old ->
          %{role: effective_role_name, status: state.status, model: state.model}
        end)

        # Update Context agent info
        Context.register_agent(state.team_id, state.name, %{
          role: effective_role_name,
          status: state.status,
          model: state.model
        })

        # Log role transition to decision graph
        log_role_change_to_graph(state.team_id, state.name, old_role, effective_role_name)

        # Broadcast role change to team
        broadcast_team(state, {:role_changed, state.name, old_role, effective_role_name})

        Logger.info(
          "[Agent:#{state.name}] Role changed from #{old_role} to #{effective_role_name}"
        )

        {:reply, :ok, state}

      {:error, :unknown_role} ->
        {:reply, {:error, :unknown_role}, state}
    end
  end

  defp log_role_change_to_graph(team_id, agent_name, old_role, new_role) do
    Loomkin.Decisions.Graph.add_node(%{
      node_type: :observation,
      title: "Role change: #{agent_name} #{old_role} -> #{new_role}",
      description:
        "Agent #{agent_name} in team #{team_id} changed role from #{old_role} to #{new_role}.",
      status: :active,
      metadata: %{"team_id" => team_id}
    })
  rescue
    _ ->
      :ok
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
        system_prompt:
          "You are voting in a collective decision. Respond with only the chosen option text.",
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

      Loomkin.Signals.Collaboration.VoteResponse.new!(%{
        vote_id: vote_id,
        team_id: team_id
      })
      |> Map.put(:data, %{vote_id: vote_id, team_id: team_id, response: response})
      |> Loomkin.Signals.Extensions.Causality.attach(
        team_id: team_id,
        agent_name: to_string(agent_name)
      )
      |> Loomkin.Signals.publish()
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

      {:paused, reason, msgs, iteration} ->
        {:loop_paused, reason, msgs, iteration}
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
        maybe_trigger_healing(reason, messages, snapshot)
      end
    else
      maybe_trigger_healing(reason, messages, snapshot)
    end
  end

  defp maybe_trigger_healing(reason, messages, snapshot) do
    alias Loomkin.Healing.ErrorClassifier

    error_text = if is_binary(reason), do: reason, else: inspect(reason)
    classification = ErrorClassifier.classify(error_text)

    healing_policy = snapshot.healing_policy || %{}

    agent_state = %{
      failure_count: snapshot.failure_count,
      role: snapshot.role,
      healing_enabled: Map.get(healing_policy, :enabled, true),
      healing_categories: Map.get(healing_policy, :categories, []),
      failure_threshold: Map.get(healing_policy, :failure_threshold),
      healing_budget_remaining: Map.get(healing_policy, :budget_usd, 0.50)
    }

    if ErrorClassifier.should_heal?(classification, agent_state) do
      {:loop_healing_needed, classification, messages}
    else
      {:loop_error, reason, messages}
    end
  end

  defp do_escalate_in_task(reason, messages, loop_opts, snapshot) do
    old_model = snapshot.model

    case ModelRouter.escalate(old_model) do
      {:ok, next_model} ->
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

        Loomkin.Signals.Agent.Escalation.new!(%{
          agent_name: to_string(snapshot.name),
          team_id: snapshot.team_id,
          from_model: to_string(old_model),
          to_model: to_string(next_model)
        })
        |> Loomkin.Signals.Extensions.Causality.attach(
          team_id: snapshot.team_id,
          agent_name: to_string(snapshot.name)
        )
        |> Loomkin.Signals.publish()

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

          {:paused, pause_reason, msgs, iteration} ->
            {:loop_paused, pause_reason, msgs, iteration}
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
      role: state.role,
      healing_policy: state.role_config && state.role_config.healing_policy
    }
  end

  defp drain_queues(state) do
    had_messages? = state.priority_queue != [] or state.pending_updates != []

    if had_messages? do
      Logger.debug(
        "[Kin:queue] draining agent=#{state.name} priority=#{length(state.priority_queue)} normal=#{length(state.pending_updates)}"
      )
    end

    Enum.each(state.priority_queue, fn qm -> send(self(), QueuedMessage.to_dispatchable(qm)) end)

    Enum.each(state.pending_updates, fn qm ->
      send(self(), QueuedMessage.to_dispatchable(qm))
    end)

    state = %{state | priority_queue: [], pending_updates: []}
    if had_messages?, do: broadcast_queue_update(state)
    state
  end

  # Schedule a wake-up for an idle agent after a short debounce.
  # This coalesces rapid-fire messages so we don't start multiple loops.
  defp maybe_wake_idle(state) do
    if state.status == :idle and state.loop_task == nil and state.wake_ref == nil do
      ref = Process.send_after(self(), :wake_up, 500)
      %{state | wake_ref: ref}
    else
      state
    end
  end

  defp drain_healing_queue(state) do
    Enum.each(state.healing_queue, fn qm ->
      send(self(), QueuedMessage.to_dispatchable(qm))
    end)

    %{state | healing_queue: []}
  end

  defp maybe_rerun_after_healing(state) do
    if state.task do
      # Agent had an active task before suspension — re-run the loop to continue
      loop_opts = build_loop_opts(state)
      snapshot = build_snapshot(state)

      task =
        Task.Supervisor.async_nolink(Loomkin.Teams.TaskSupervisor, fn ->
          run_loop_with_escalation(state.messages, loop_opts, snapshot)
        end)

      state = set_status_and_broadcast(state, :working)
      %{state | loop_task: {task, nil}}
    else
      state
    end
  end

  defp list_full_queue(state) do
    state.priority_queue ++ state.pending_updates
  end

  defp broadcast_queue_update(state) do
    queue =
      list_full_queue(state)
      |> Enum.map(&QueuedMessage.to_serializable/1)

    Loomkin.Signals.Agent.QueueUpdated.new!(%{
      agent_name: to_string(state.name),
      team_id: state.team_id
    })
    |> Map.put(:data, %{
      agent_name: to_string(state.name),
      team_id: state.team_id,
      queue: queue
    })
    |> Loomkin.Signals.Extensions.Causality.attach(
      team_id: state.team_id,
      agent_name: to_string(state.name)
    )
    |> Loomkin.Signals.publish()
  rescue
    _ ->
      :ok
  end

  defp update_queued_message(state, message_id, update_fn) do
    case find_and_update_in(state.priority_queue, message_id, update_fn) do
      {:ok, updated} ->
        {true, %{state | priority_queue: updated}}

      :not_found ->
        case find_and_update_in(state.pending_updates, message_id, update_fn) do
          {:ok, updated} ->
            {true, %{state | pending_updates: updated}}

          :not_found ->
            {false, state}
        end
    end
  end

  defp find_and_update_in(queue, message_id, update_fn) do
    case Enum.split_while(queue, fn qm -> qm.id != message_id end) do
      {_before, []} ->
        :not_found

      {before, [target | after_target]} ->
        {:ok, before ++ [update_fn.(target) | after_target]}
    end
  end

  defp squash_contents(contents) do
    # Extract text from inject_system_message tuples, concatenate
    texts =
      Enum.map(contents, fn
        {:inject_system_message, text} when is_binary(text) -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)

    {:inject_system_message, Enum.join(texts, "\n---\n")}
  end

  defp handle_urgent({:abort_task, _reason}, state) do
    case state.loop_task do
      {%Task{} = task, from} ->
        Task.shutdown(task, :brutal_kill)
        task_id = state.task && state.task[:id]
        if task_id, do: Loomkin.Teams.Tasks.fail_task(task_id, "aborted")
        if from, do: GenServer.reply(from, {:error, :aborted})
        state = %{state | loop_task: nil, pending_updates: [], priority_queue: []}
        state = set_status_and_broadcast(state, :idle)
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
        state = set_status_and_broadcast(state, :idle)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_urgent({:file_conflict, details}, state) do
    # Queue as an internal message so it survives the loop result handler
    # (which overwrites state.messages with the task-returned msgs).
    inject = {:inject_system_message, "[URGENT] File conflict detected: #{inspect(details)}"}
    qm = QueuedMessage.new(inject, priority: :urgent, source: :system)
    state = %{state | priority_queue: state.priority_queue ++ [qm]}
    broadcast_queue_update(state)
    {:noreply, state}
  end

  defp handle_urgent(_msg, state) do
    {:noreply, state}
  end

  @doc false
  def resolve_project_path(team_id, fallback) do
    case Manager.get_team_project_path(team_id) do
      nil ->
        Logger.warning(
          "[Kin:agent] project_path ETS lookup failed for team=#{team_id}, using fallback=#{fallback}"
        )

        fallback

      path ->
        path
    end
  end

  defp build_loop_opts(state) do
    team_id = state.team_id
    name = state.name
    # Capture Agent GenServer PID here — closures below run inside async Task
    # where self() would return the Task PID, not the Agent PID.
    agent_pid = self()
    system_prompt = inject_keeper_index(state.role_config.system_prompt, team_id)
    permission_callback = build_permission_callback(state)
    checkpoint_callback = build_checkpoint_callback()

    # Orchestrator mode: Lead agents with specialists lose tactical tools.
    {tools, system_prompt} = maybe_apply_orchestrator_mode(state, system_prompt)

    # Kin agent customization: append user-defined extra instructions if present.
    system_prompt = maybe_inject_system_prompt_extra(system_prompt, state)

    # Project conventions are injected by context_window.ex:inject_project_rules/2
    # during build_messages/3 (with ETS caching), so we don't duplicate here.

    # A resolver fn allows AgentLoop to read the latest project_path from
    # team ETS at every tool call, even when the Task captured stale opts.
    project_path_resolver = fn -> resolve_project_path(team_id, state.project_path) end

    [
      model: state.model,
      tools: tools,
      role: state.role,
      system_prompt: system_prompt,
      project_path: state.project_path,
      project_path_resolver: project_path_resolver,
      agent_name: state.name,
      team_id: state.team_id,
      session_id: state.session_id,
      # Agents do not carry an authenticated user — disk skills load via
      # load_from_disk/1 at session bootstrap; DB skills require a user.
      user: nil,
      reasoning_strategy: state.role_config.reasoning_strategy,
      check_permission: permission_callback,
      checkpoint: checkpoint_callback,
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
        # Rate-limit check happens first via GenServer.call to read live state.
        if tool_module == Loomkin.Tools.AskUser do
          case GenServer.call(agent_pid, {:check_ask_user_rate_limit, tool_args}) do
            :allow ->
              atomized = Loomkin.Tools.Registry.atomize_keys(tool_args)

              result =
                try do
                  tool_module.run(atomized, context)
                rescue
                  e -> {:error, Exception.message(e)}
                end

              # After run/2 returns (question was answered), notify GenServer
              # to update last_asked_at and clear the pending card.
              # Use a sentinel ID — the :allow path has questions: [], so any ID
              # triggers the "all answered" cleanup in ask_user_answered.
              GenServer.call(agent_pid, {:ask_user_answered, :allow_cleanup})

              AgentLoop.format_tool_result(result)

            {:batch, card_id} ->
              # Append question to open card and block tool task waiting for answer
              question_id = Ecto.UUID.generate()
              tool_task_pid = self()

              # Register in the tool task process so answers route here (self() = task pid)
              Registry.register(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}, self())

              GenServer.cast(
                agent_pid,
                {:append_ask_user_question, tool_args, card_id, question_id, tool_task_pid}
              )

              receive do
                {:ask_user_answer, ^question_id, answer} ->
                  Registry.unregister(Loomkin.Teams.AgentRegistry, {:ask_user, question_id})
                  GenServer.call(agent_pid, {:ask_user_answered, question_id})

                  AgentLoop.format_tool_result(
                    {:ok, %{result: "User answered: #{answer}", answer: answer}}
                  )
              after
                300_000 ->
                  # Timeout: clear the question and proceed autonomously
                  Registry.unregister(Loomkin.Teams.AgentRegistry, {:ask_user, question_id})
                  GenServer.call(agent_pid, {:ask_user_answered, question_id})

                  AgentLoop.format_tool_result(
                    {:ok, %{result: "Collective: timeout — proceeding autonomously", answer: nil}}
                  )
              end

            :drop ->
              AgentLoop.format_tool_result(
                {:ok,
                 %{
                   result:
                     "Rate limit reached — proceeding autonomously. Your question was not shown to the human.",
                   answer: nil
                 }}
              )
          end
        else
          if tool_module == Loomkin.Tools.TeamSpawn do
            run_spawn_gate_intercept(agent_pid, tool_module, tool_args, context, team_id, name)
          else
            AgentLoop.default_run_tool(tool_module, tool_args, context)
          end
        end
      end
    ]
  end

  # -- Structured predecessor handoff formatting --

  defp format_predecessor_output(output) do
    lines = ["### #{output.title}", "Result: #{output[:result]}"]

    lines =
      lines
      |> maybe_append_list("Files changed", output[:files_changed])
      |> maybe_append_list("Decisions", output[:decisions_made])
      |> maybe_append_list("Discoveries", output[:discoveries])
      |> maybe_append_list("Open questions", output[:open_questions])
      |> maybe_append_list("Actions taken", output[:actions_taken])

    Enum.join(lines, "\n")
  end

  defp maybe_append_list(lines, _label, nil), do: lines
  defp maybe_append_list(lines, _label, []), do: lines

  defp maybe_append_list(lines, label, items),
    do: lines ++ ["#{label}: #{Enum.join(items, "; ")}"]

  # -- Orchestrator mode helpers --

  defp maybe_apply_orchestrator_mode(state, system_prompt) do
    orchestrator_enabled? =
      case Loomkin.Config.get(:teams, :orchestrator_mode) do
        false -> false
        _ -> true
      end

    if state.role == :lead and orchestrator_enabled? and
         has_specialists?(state.team_id, state.name) do
      {Role.orchestrator_tools(), system_prompt <> "\n\n" <> Role.orchestrator_prompt_addition()}
    else
      {state.tools, system_prompt}
    end
  end

  defp maybe_inject_system_prompt_extra(system_prompt, state) do
    case state.system_prompt_extra do
      extra when is_binary(extra) and extra != "" ->
        system_prompt <> "\n\n## Additional Instructions\n" <> extra

      _ ->
        system_prompt
    end
  end

  @non_specialist_roles [:lead, :concierge, :orienter, "lead", "concierge", "orienter"]

  defp has_specialists?(team_id, my_name) do
    Manager.list_agents(team_id)
    |> Enum.any?(fn agent ->
      to_string(agent.name) != to_string(my_name) and
        agent.role not in @non_specialist_roles
    end)
  end

  # -- Spawn gate intercept helpers --

  @role_cost_estimates %{
    "researcher" => 0.20,
    "coder" => 0.50,
    "reviewer" => 0.30,
    "tester" => 0.30,
    "lead" => 0.50,
    "concierge" => 0.10
  }

  @default_max_agents_per_team 10

  defp run_spawn_gate_intercept(agent_pid, tool_module, tool_args, context, team_id, agent_name) do
    spawn_type = Map.get(tool_args, "spawn_type", Map.get(tool_args, :spawn_type))

    if spawn_type in [:research, "research"] do
      run_research_spawn(agent_pid, tool_module, tool_args, context, team_id, agent_name)
    else
      run_human_or_auto_spawn_gate(
        agent_pid,
        tool_module,
        tool_args,
        context,
        team_id,
        agent_name
      )
    end
  end

  defp run_research_spawn(agent_pid, tool_module, tool_args, context, team_id, agent_name) do
    roles = tool_args |> Map.get("roles", Map.get(tool_args, :roles, [])) |> atomize_role_keys()
    estimated_cost = estimate_spawn_cost(roles)
    researcher_count = length(roles)

    # Budget check still runs for research spawns
    case GenServer.call(agent_pid, {:check_spawn_budget, estimated_cost}) do
      {:budget_exceeded, details} ->
        AgentLoop.format_tool_result({:error, :budget_exceeded, details})

      :ok ->
        # Register tool task in Registry before entering awaiting_synthesis
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {:awaiting_synthesis, team_id, agent_name},
          self()
        )

        # Transition agent to :awaiting_synthesis
        GenServer.cast(agent_pid, {:enter_awaiting_synthesis, researcher_count})

        # Execute spawn (nil gate_id = no GateResolved published; no human gate opened)
        spawn_result =
          execute_spawn_and_notify(
            agent_pid,
            tool_module,
            tool_args,
            context,
            nil,
            team_id,
            agent_name
          )

        # If spawn failed, exit awaiting_synthesis immediately instead of blocking 120s
        findings =
          case spawn_result do
            {:error, _reason} ->
              GenServer.cast(agent_pid, :exit_awaiting_synthesis)

              Registry.unregister(
                Loomkin.Teams.AgentRegistry,
                {:awaiting_synthesis, team_id, agent_name}
              )

              []

            _ ->
              # Block in receive loop collecting findings from researchers
              collect_research_findings(researcher_count, 120_000, [])
          end

        # Exit awaiting_synthesis; agent returns to :working
        GenServer.cast(agent_pid, :exit_awaiting_synthesis)

        summary =
          findings
          |> Enum.map(fn {from, content} -> "--- #{from} ---\n#{content}" end)
          |> Enum.join("\n\n")

        {:ok, %{result: "Research synthesis complete.\n\n#{summary}"}}
    end
  end

  defp collect_research_findings(0, _timeout_ms, acc), do: Enum.reverse(acc)

  defp collect_research_findings(count, timeout_ms, acc) when count > 0 do
    receive do
      {:research_findings, from, content} ->
        collect_research_findings(count - 1, timeout_ms, [{from, content} | acc])
    after
      timeout_ms ->
        # partial findings on timeout — proceed with what arrived
        Enum.reverse(acc)
    end
  end

  defp run_human_or_auto_spawn_gate(
         agent_pid,
         tool_module,
         tool_args,
         context,
         team_id,
         agent_name
       ) do
    roles = tool_args |> Map.get("roles", Map.get(tool_args, :roles, [])) |> atomize_role_keys()
    estimated_cost = estimate_spawn_cost(roles)

    # Step 2: guard against double-gate
    if GenServer.call(agent_pid, :is_gate_open?) do
      AgentLoop.format_tool_result(
        {:error, :approval_pending, %{message: "Agent already has an open approval gate"}}
      )
    else
      # Step 3: budget check
      case GenServer.call(agent_pid, {:check_spawn_budget, estimated_cost}) do
        {:budget_exceeded, details} ->
          AgentLoop.format_tool_result({:error, :budget_exceeded, details})

        :ok ->
          # Step 4: check auto-approve setting (read via GenServer for freshness)
          %{auto_approve_spawns: auto_approve} = GenServer.call(agent_pid, :get_spawn_settings)

          if auto_approve do
            # Step 6 directly: execute spawn
            execute_spawn_and_notify(
              agent_pid,
              tool_module,
              tool_args,
              context,
              nil,
              team_id,
              agent_name
            )
          else
            run_human_spawn_gate(
              agent_pid,
              tool_module,
              tool_args,
              context,
              team_id,
              agent_name,
              estimated_cost,
              roles,
              auto_approve
            )
          end
      end
    end
  end

  defp run_human_spawn_gate(
         agent_pid,
         tool_module,
         tool_args,
         context,
         team_id,
         agent_name,
         estimated_cost,
         roles,
         auto_approve
       ) do
    gate_id = Ecto.UUID.generate()

    team_name =
      Map.get(tool_args, "team_name", Map.get(tool_args, :team_name, nil)) ||
        Map.get(tool_args, "name", Map.get(tool_args, :name, "unnamed-team"))

    purpose =
      Map.get(tool_args, "purpose", Map.get(tool_args, :purpose, nil))

    timeout_ms =
      Map.get(tool_args, "timeout_ms", Map.get(tool_args, :timeout_ms, nil)) ||
        Application.get_env(:loomkin, :spawn_gate_timeout_ms, 300_000)

    limit_warning = compute_limit_warning(team_id, length(roles))

    pending_info = %{
      type: :spawn_gate,
      gate_id: gate_id,
      team_name: team_name,
      purpose: purpose,
      roles: roles,
      estimated_cost: estimated_cost,
      limit_warning: limit_warning
    }

    # Register this tool task process for response routing before casting (prevents race condition
    # where LiveView receives the signal and user approves before the gate_id is registered)
    case Registry.register(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id}, self()) do
      {:error, {:already_registered, _}} ->
        AgentLoop.format_tool_result(
          {:error, :already_registered,
           %{message: "Spawn gate already registered. Cannot open a second gate."}}
        )

      _ ->
        # Open gate: mark agent approval_pending via cast (after registration to avoid race condition)
        GenServer.cast(agent_pid, {:open_spawn_gate, gate_id, pending_info})

        # Publish GateRequested signal for LiveView to render the gate ui
        signal =
          Loomkin.Signals.Spawn.GateRequested.new!(%{
            gate_id: gate_id,
            agent_name: to_string(agent_name),
            team_id: team_id,
            team_name: team_name,
            purpose: purpose,
            roles: roles,
            estimated_cost: estimated_cost,
            limit_warning: limit_warning,
            timeout_ms: timeout_ms,
            auto_approve_spawns: auto_approve
          })

        Loomkin.Signals.publish(signal)

        receive do
          {:spawn_gate_response, ^gate_id, %{outcome: :approved}} ->
            Registry.unregister(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id})

            result =
              execute_spawn_and_notify(
                agent_pid,
                tool_module,
                tool_args,
                context,
                gate_id,
                team_id,
                agent_name
              )

            # Clear approval_pending status so agent can retry team_spawn
            # within the same loop if the spawn fails.
            GenServer.cast(agent_pid, :close_spawn_gate)

            result

          {:spawn_gate_response, ^gate_id, %{outcome: :denied, reason: reason}} ->
            Registry.unregister(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id})

            # Clear approval_pending status on denial
            GenServer.cast(agent_pid, :close_spawn_gate)

            resolved =
              Loomkin.Signals.Spawn.GateResolved.new!(%{
                gate_id: gate_id,
                agent_name: to_string(agent_name),
                team_id: team_id,
                outcome: :denied
              })

            Loomkin.Signals.publish(resolved)

            AgentLoop.format_tool_result(
              {:ok,
               %{
                 status: :denied,
                 reason: :human_denied,
                 message: reason || "Denied by human."
               }}
            )
        after
          timeout_ms ->
            Registry.unregister(Loomkin.Teams.AgentRegistry, {:spawn_gate, gate_id})

            # Clear approval_pending status on timeout
            GenServer.cast(agent_pid, :close_spawn_gate)

            resolved =
              Loomkin.Signals.Spawn.GateResolved.new!(%{
                gate_id: gate_id,
                agent_name: to_string(agent_name),
                team_id: team_id,
                outcome: :timeout
              })

            Loomkin.Signals.publish(resolved)

            AgentLoop.format_tool_result(
              {:ok,
               %{
                 status: :denied,
                 reason: :timeout,
                 message: "Spawn gate timed out."
               }}
            )
        end
    end
  end

  defp execute_spawn_and_notify(
         agent_pid,
         tool_module,
         tool_args,
         context,
         gate_id,
         team_id,
         agent_name
       ) do
    result = AgentLoop.default_run_tool(tool_module, tool_args, context)

    if gate_id do
      # Publish GateResolved for approved path (human gate)
      resolved =
        Loomkin.Signals.Spawn.GateResolved.new!(%{
          gate_id: gate_id,
          agent_name: to_string(agent_name),
          team_id: team_id,
          outcome: :approved
        })

      Loomkin.Signals.publish(resolved)
    end

    # Preserve existing child_team_spawned notify
    case result do
      {:ok, %{team_id: child_team_id}} ->
        send(agent_pid, {:child_team_spawned, child_team_id})

      _ ->
        :ok
    end

    result
  end

  @string_to_atom_keys %{
    "name" => :name,
    "role" => :role,
    "model" => :model,
    "system_prompt" => :system_prompt,
    "count" => :count
  }

  defp atomize_role_keys(roles) when is_list(roles) do
    Enum.map(roles, fn
      role when is_map(role) ->
        Map.new(role, fn
          {k, v} when is_binary(k) -> {Map.get(@string_to_atom_keys, k, k), v}
          {k, v} -> {k, v}
        end)

      other ->
        other
    end)
  end

  defp atomize_role_keys(other), do: other

  defp estimate_spawn_cost(roles) when is_list(roles) do
    Enum.reduce(roles, 0.0, fn role, acc ->
      role_str =
        cond do
          is_map(role) -> to_string(Map.get(role, "role", Map.get(role, :role, "researcher")))
          is_binary(role) -> role
          is_atom(role) -> to_string(role)
          true -> "researcher"
        end

      cost = Map.get(@role_cost_estimates, role_str, 0.20)
      acc + cost
    end)
  end

  defp estimate_spawn_cost(_), do: 0.20

  # Mirroring Manager's @default_max_nesting_depth = 2
  @spawn_max_nesting_depth 2

  defp compute_limit_warning(team_id, planned_agent_count) do
    # Check depth warning: if team depth + 1 >= 80% of max depth (2), warn
    # 80% of 2 = 1.6 → floor = 1, so any depth >= 1 approaching limit of 2
    depth_threshold = floor(@spawn_max_nesting_depth * 0.8)

    current_depth =
      case Manager.get_team_meta(team_id) do
        {:ok, %{depth: d}} -> d
        _ -> 0
      end

    if current_depth >= depth_threshold do
      :depth
    else
      # Check agent count warning: planned spawn total >= 80% of max agents
      agent_threshold = floor(@default_max_agents_per_team * 0.8)

      if planned_agent_count >= agent_threshold do
        :agents
      else
        nil
      end
    end
  end

  defp build_permission_callback(%{permission_mode: :auto}), do: nil

  defp build_permission_callback(%{
         permission_mode: :session,
         team_id: team_id,
         session_id: session_id,
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
          Loomkin.Permissions.Manager.check(tool_name_str, tool_path, session_id, project_path)
        else
          Loomkin.Permissions.Manager.check(tool_name_str, tool_path, session_id)
        end

      case check_result do
        :allowed ->
          :allowed

        :ask ->
          Loomkin.Signals.Team.PermissionRequest.new!(%{
            team_id: team_id,
            tool_name: tool_name_str,
            tool_path: resolved_path || ""
          })
          |> Map.put(:data, %{
            team_id: team_id,
            tool_name: tool_name_str,
            tool_path: resolved_path,
            source: {:agent, team_id, agent_name}
          })
          |> Loomkin.Signals.Extensions.Causality.attach(
            team_id: team_id,
            agent_name: to_string(agent_name)
          )
          |> Loomkin.Signals.publish()

          {:pending, %{tool_name: tool_name_str, tool_path: resolved_path}}
      end
    end
  end

  defp build_permission_callback(_state), do: nil

  defp build_checkpoint_callback do
    # Capture self() at build time — this is the Agent GenServer pid.
    # The callback runs inside the async Task and calls back to the GenServer.
    agent_pid = self()

    fn checkpoint ->
      GenServer.call(agent_pid, {:checkpoint, checkpoint}, 30_000)
    end
  end

  defp check_scope_envelope(%{scope_tier: nil}), do: :ok

  defp check_scope_envelope(state) do
    file_count = MapSet.size(state.files_touched)
    ScopeDetector.exceeded?(state.scope_tier, %{files: file_count, cost: state.task_cost_usd})
  end

  defp broadcast_scope_gate(state, tier, trigger, details) do
    agent_str = to_string(state.name)

    try do
      Loomkin.Signals.Agent.ScopeGate.new!(
        %{agent_name: agent_str, team_id: state.team_id, tier: tier, trigger: trigger},
        subject: "payload"
      )
      |> Map.put(:data, %{
        agent_name: agent_str,
        team_id: state.team_id,
        tier: tier,
        trigger: trigger,
        current: details.current,
        limit: details.limit
      })
      |> Loomkin.Signals.Extensions.Causality.attach(
        team_id: state.team_id,
        agent_name: agent_str
      )
      |> Loomkin.Signals.publish()
    rescue
      _ -> :ok
    end
  end

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
    _ ->
      state.messages
  end

  @keeper_index_cap 10

  defp inject_keeper_index(prompt, team_id) do
    keepers = ContextRetrieval.list_keepers(team_id)

    index_text =
      case keepers do
        [] ->
          "none yet"

        list ->
          total = length(list)

          shown =
            list
            |> Enum.sort_by(& &1.staleness, :asc)
            |> Enum.take(@keeper_index_cap)

          lines =
            Enum.map_join(shown, "\n", fn k ->
              "- [#{k.id}] \"#{k.topic}\" by #{k.source_agent} (#{k.token_count} tokens)"
            end)

          if total > @keeper_index_cap do
            lines <>
              "\n[#{length(shown)} of #{total} keepers shown — use search_keepers tool for more]"
          else
            lines
          end
      end

    if String.contains?(prompt, "{keeper_index}") do
      String.replace(prompt, "{keeper_index}", index_text)
    else
      prompt <> "\n\nAvailable Keepers:\n" <> index_text
    end
  end

  @stream_throttle_ms 100

  # Extracts the text chunk from a stream delta payload.
  defp extract_delta_text(payload) do
    case payload do
      %{text: t} when is_binary(t) -> t
      %{content: c} when is_binary(c) -> c
      %{delta: d} when is_binary(d) -> d
      c when is_binary(c) -> c
      _ -> ""
    end
  end

  # Flushes any buffered stream delta content as a single batched signal.
  defp flush_stream_buffer(team_id, agent_str) do
    buffer = Process.get(:stream_buffer, "")

    if buffer != "" do
      Process.put(:stream_buffer, "")
      Process.put(:stream_last_flush, System.monotonic_time(:millisecond))

      signal =
        Loomkin.Signals.Agent.StreamDelta.new!(%{agent_name: agent_str, team_id: team_id},
          subject: "payload"
        )
        |> Map.put(
          :data,
          Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, %{text: buffer})
        )
        |> Loomkin.Signals.Extensions.Causality.attach(
          team_id: team_id,
          agent_name: agent_str
        )

      Loomkin.Signals.publish(signal)
    end
  end

  defp handle_loop_event(team_id, agent_name, event_name, payload) do
    agent_str = to_string(agent_name)

    signal =
      case event_name do
        :stream_start ->
          # Reset buffer state at start of a new stream
          Process.put(:stream_buffer, "")
          Process.put(:stream_last_flush, System.monotonic_time(:millisecond))

          Loomkin.Signals.Agent.StreamStart.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :stream_delta ->
          # Accumulate tokens and only publish when throttle interval has elapsed
          chunk = extract_delta_text(payload)
          buffer = Process.get(:stream_buffer, "") <> chunk
          Process.put(:stream_buffer, buffer)

          last_flush = Process.get(:stream_last_flush, 0)
          now = System.monotonic_time(:millisecond)

          if now - last_flush >= @stream_throttle_ms do
            flush_stream_buffer(team_id, agent_str)
          end

          # Return nil — signal was published by flush or will be later
          nil

        :stream_end ->
          # Flush any remaining buffered content before ending
          flush_stream_buffer(team_id, agent_str)

          Loomkin.Signals.Agent.StreamEnd.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :tool_executing ->
          Loomkin.Signals.Agent.ToolExecuting.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :tool_complete ->
          Loomkin.Signals.Agent.ToolComplete.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :usage ->
          Loomkin.Signals.Agent.Usage.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :context_offloaded ->
          Loomkin.Signals.Context.Offloaded.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :tool_error ->
          Loomkin.Signals.Agent.Error.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :max_iterations_exceeded ->
          Loomkin.Signals.Agent.Error.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        :cycle_detected ->
          Loomkin.Signals.Agent.Error.new!(%{agent_name: agent_str, team_id: team_id},
            subject: "payload"
          )
          |> Map.put(
            :data,
            Map.put(%{agent_name: agent_str, team_id: team_id}, :payload, payload)
          )

        _ ->
          nil
      end

    if signal do
      signal
      |> Loomkin.Signals.Extensions.Causality.attach(
        team_id: team_id,
        agent_name: agent_str
      )
      |> Loomkin.Signals.publish()
    end
  rescue
    _ ->
      :ok
  end

  defp track_usage(state, %{usage: usage}) do
    total_tokens = (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
    raw_cost = usage[:total_cost] || 0

    cost =
      if raw_cost > 0 do
        raw_cost
      else
        Loomkin.Teams.Pricing.calculate_cost(
          state.model,
          usage[:input_tokens] || 0,
          usage[:output_tokens] || 0
        )
      end

    case RateLimiter.record_usage(state.team_id, to_string(state.name), %{
           tokens: total_tokens,
           cost: cost
         }) do
      {:budget_exceeded, _scope} ->
        :ok

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
        task_cost_usd: state.task_cost_usd + cost,
        tokens_used: state.tokens_used + total_tokens
    }
  end

  defp track_usage(state, _metadata), do: state

  defp set_status(state, new_status) do
    Registry.update_value(Loomkin.Teams.AgentRegistry, {state.team_id, state.name}, fn _old ->
      %{role: state.role, status: new_status, model: state.model}
    end)

    Context.update_agent_status(state.team_id, state.name, new_status)

    %{state | status: new_status}
  end

  # Sets status and broadcasts only when the status actually changed.
  # This prevents duplicate `:agent_status` signals when multiple code paths
  # set the same status (e.g., :working broadcast from both send_message and execute_task).
  defp set_status_and_broadcast(state, new_status) do
    if state.status == new_status do
      state
    else
      old_status = state.status
      state = set_status(state, new_status)

      broadcast_team(
        state,
        {:agent_status, state.name, new_status,
         %{previous_status: old_status, pause_queued: state.pause_queued}}
      )

      # Emit agent ready signal when transitioning from working to idle
      if new_status == :idle and old_status in [:working, :waiting_permission] do
        maybe_broadcast_agent_ready(state)
      end

      # Save checkpoint when entering paused state
      if new_status == :paused do
        save_checkpoint_async(state, :paused)
      end

      # Delete all checkpoints on successful completion to prevent stale resurrection
      if new_status == :idle and old_status in [:working, :thinking] do
        delete_all_checkpoints_async(state)
      end

      state
    end
  end

  defp maybe_broadcast_agent_ready(state) do
    task_id = state.task && state.task[:id]

    signal =
      Loomkin.Signals.Agent.Ready.new!(%{
        agent_name: to_string(state.name),
        team_id: state.team_id,
        ready_for: "new_task",
        task_id: if(task_id, do: to_string(task_id), else: nil)
      })

    Loomkin.Signals.publish(signal)
  rescue
    _ -> :ok
  end

  defp handle_peer_message_signal(sig, state) do
    msg = sig.data[:message]

    case msg do
      {:peer_message, from, content} ->
        handle_info({:peer_message, from, content}, state)

      {:context_update, from, payload} ->
        handle_info({:context_update, from, payload}, state)

      {:inject_system_message, _} = tuple ->
        handle_info(tuple, state)

      {:debate_start, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:debate_propose, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:debate_critique, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:debate_revise, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:debate_vote, _, _} = tuple ->
        handle_info(tuple, state)

      {:pair_started, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:pair_stopped, _} = tuple ->
        handle_info(tuple, state)

      {:pair_broadcast, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:discovery_relevant, _} = tuple ->
        handle_info(tuple, state)

      {:rebalance_needed, _, _} = tuple ->
        handle_info(tuple, state)

      {:conflict_detected, _} = tuple ->
        handle_info(tuple, state)

      {:query, _, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:query_answer, _, _, _, _} = tuple ->
        handle_info(tuple, state)

      {:confidence_warning, _} = tuple ->
        handle_info(tuple, state)

      {:sub_team_completed, _} = tuple ->
        handle_info(tuple, state)

      _ ->
        # Only inject unrecognized broadcast messages into lead/concierge agents
        # to avoid redundant context copies across all team members
        if state.role in [:lead, :concierge] do
          from = sig.data[:from] || "unknown"
          content = if is_binary(msg), do: msg, else: inspect(msg)
          handle_info({:peer_message, from, content}, state)
        else
          {:noreply, state}
        end
    end
  end

  # Check if a signal belongs to this agent's team by inspecting the signal's data or
  # causality extensions for a team_id field. Signals without team_id are accepted
  # (they may be system-level signals).
  defp signal_for_this_team?(sig, state) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_team_id == nil or signal_team_id == state.team_id or
      child_team_signal_allowed?(sig.type, signal_team_id, state)
  end

  # Allow specific signal types from child teams to reach parent team agents.
  # Only lead/concierge roles receive these to avoid noise for worker agents.
  @child_team_signal_types ~w[
    team.task.completed
    team.task.failed
    team.task.blocked
    team.task.partially_complete
  ]

  defp child_team_signal_allowed?(type, signal_team_id, state)
       when type in @child_team_signal_types and not is_nil(signal_team_id) do
    state.role in [:lead, :concierge] and
      signal_team_id in Loomkin.Teams.Manager.get_child_teams(state.team_id)
  end

  defp child_team_signal_allowed?(_type, _signal_team_id, _state), do: false

  defp format_child_task_result(task, owner, child_team_id) do
    header =
      "[Sub-team result] Agent #{owner} in child team #{child_team_id} completed task: #{task.title}"

    sections =
      [
        if(task.result && task.result != "", do: "\n**Result:** #{task.result}"),
        format_list_section("Actions taken", task.actions_taken),
        format_list_section("Discoveries", task.discoveries),
        format_list_section("Files changed", task.files_changed),
        format_list_section("Decisions made", task.decisions_made),
        format_list_section("Open questions", task.open_questions)
      ]
      |> Enum.reject(&is_nil/1)

    [header | sections] |> Enum.join("")
  end

  defp format_list_section(_label, nil), do: nil
  defp format_list_section(_label, []), do: nil

  defp format_list_section(label, items) when is_list(items) do
    formatted = Enum.map_join(items, "\n  - ", & &1)
    "\n**#{label}:**\n  - #{formatted}"
  end

  defp broadcast_team(state, {:agent_status, agent_name, status, metadata}) do
    Loomkin.Signals.Agent.Status.new!(%{
      agent_name: to_string(agent_name),
      team_id: state.team_id,
      status: status,
      previous_status: metadata[:previous_status],
      pause_queued: metadata[:pause_queued] || false
    })
    |> Loomkin.Signals.Extensions.Causality.attach(
      team_id: state.team_id,
      agent_name: to_string(agent_name)
    )
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning("[Kin:agent] broadcast_team failed: #{inspect(e)}")
      :ok
  end

  defp broadcast_team(state, {:agent_status, agent_name, status}) do
    broadcast_team(state, {:agent_status, agent_name, status, %{}})
  end

  defp broadcast_team(state, {:agent_pause_queued, agent_name}) do
    # Reuse agent_status signal to notify that pause has been queued
    Loomkin.Signals.Agent.Status.new!(%{
      agent_name: to_string(agent_name),
      team_id: state.team_id,
      status: :pause_queued
    })
    |> Loomkin.Signals.Extensions.Causality.attach(
      team_id: state.team_id,
      agent_name: to_string(agent_name)
    )
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning("[Kin:agent] broadcast_team failed: #{inspect(e)}")
      :ok
  end

  defp broadcast_team(state, {:role_changed, agent_name, old_role, new_role}) do
    Loomkin.Signals.Agent.RoleChanged.new!(%{
      agent_name: to_string(agent_name),
      team_id: state.team_id,
      old_role: old_role,
      new_role: new_role
    })
    |> Loomkin.Signals.Extensions.Causality.attach(
      team_id: state.team_id,
      agent_name: to_string(agent_name)
    )
    |> Loomkin.Signals.publish()
  rescue
    e ->
      Logger.warning("[Kin:agent] broadcast_team failed: #{inspect(e)}")
      :ok
  end

  defp format_conversation_synthesis(summary, conversation_id, topic) do
    parts = ["Topic: #{topic}", "Conversation ID: #{conversation_id}"]

    parts =
      parts ++
        format_summary_list("Key points", summary[:key_points]) ++
        format_summary_list("Consensus", summary[:consensus]) ++
        format_summary_list("Disagreements", summary[:disagreements]) ++
        format_summary_list("Open questions", summary[:open_questions]) ++
        format_summary_list("Recommended actions", summary[:recommended_actions])

    Enum.join(parts, "\n")
  end

  defp format_summary_list(_label, nil), do: []
  defp format_summary_list(_label, []), do: []

  defp format_summary_list(label, items) when is_list(items) do
    formatted = Enum.map_join(items, "\n", fn item -> "  - #{item}" end)
    ["#{label}:\n#{formatted}"]
  end

  # --- Checkpoint persistence ---

  @stale_checkpoint_hours 24

  defp maybe_restore_from_checkpoint(state) do
    case Checkpoints.latest_checkpoint(state.team_id, to_string(state.name),
           session_id: state.session_id
         ) do
      nil ->
        state

      checkpoint ->
        case AgentState.deserialize(checkpoint.state_binary) do
          {:ok, essential} ->
            state = AgentState.restore_into_agent(state, essential)

            # Determine restored status
            state =
              case checkpoint.status do
                :paused -> %{state | status: :paused}
                # Hibernated and crashed agents resume as idle
                _ -> %{state | status: :idle}
              end

            # Inject resume guidance as a system message
            staleness_warning = checkpoint_staleness_warning(checkpoint)

            guidance_parts =
              [
                checkpoint.resume_guidance,
                staleness_warning,
                "Restored from checkpoint (status: #{checkpoint.status}, iteration: #{checkpoint.iteration})."
              ]
              |> Enum.reject(&is_nil/1)

            guidance_msg = %{
              role: :system,
              content: "[Checkpoint Restore] " <> Enum.join(guidance_parts, " ")
            }

            state = %{state | messages: state.messages ++ [guidance_msg]}

            Logger.info(
              "[Kin:checkpoint] restored agent=#{state.name} team=#{state.team_id} " <>
                "checkpoint_status=#{checkpoint.status} messages=#{length(state.messages)}"
            )

            state

          {:error, reason} ->
            Logger.warning(
              "[Kin:checkpoint] failed to deserialize agent=#{state.name} " <>
                "team=#{state.team_id} reason=#{inspect(reason)}"
            )

            state
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Kin:checkpoint] restore failed agent=#{state.name} team=#{state.team_id} error=#{inspect(e)}"
      )

      state
  end

  defp checkpoint_staleness_warning(checkpoint) do
    age_hours =
      DateTime.diff(DateTime.utc_now(), checkpoint.inserted_at, :second) / 3600.0

    if age_hours > @stale_checkpoint_hours do
      "WARNING: This checkpoint is #{Float.round(age_hours, 1)} hours old and may be stale."
    else
      nil
    end
  end

  defp save_checkpoint_async(state, checkpoint_status) do
    attrs = build_checkpoint_attrs(state, checkpoint_status, nil)

    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      case Checkpoints.create_checkpoint(attrs) do
        {:ok, _} ->
          Logger.info(
            "[Kin:checkpoint] saved status=#{checkpoint_status} agent=#{state.name} team=#{state.team_id}"
          )

        {:error, changeset} ->
          Logger.warning(
            "[Kin:checkpoint] failed to save agent=#{state.name} error=#{inspect(changeset.errors)}"
          )
      end
    end)
  end

  defp save_checkpoint_sync(state, checkpoint_status, resume_guidance) do
    attrs = build_checkpoint_attrs(state, checkpoint_status, resume_guidance)

    case Checkpoints.create_checkpoint(attrs) do
      {:ok, _} ->
        Logger.info(
          "[Kin:checkpoint] saved status=#{checkpoint_status} agent=#{state.name} team=#{state.team_id}"
        )

      {:error, changeset} ->
        Logger.warning(
          "[Kin:checkpoint] failed to save agent=#{state.name} error=#{inspect(changeset.errors)}"
        )
    end
  end

  defp build_checkpoint_attrs(state, checkpoint_status, resume_guidance) do
    essential = AgentState.extract_essential_state(state)
    state_binary = AgentState.serialize(essential)

    iteration =
      case state.paused_state do
        %{iteration: i} when is_integer(i) -> i
        _ -> 0
      end

    %{
      team_id: state.team_id,
      agent_name: to_string(state.name),
      session_id: state.session_id,
      iteration: iteration,
      status: checkpoint_status,
      state_binary: state_binary,
      messages_snapshot: %{count: length(state.messages)},
      task_context:
        if(state.task, do: Map.take(state.task, [:id, :title, :description]), else: nil),
      resume_guidance: resume_guidance
    }
  end

  defp delete_all_checkpoints_async(state) do
    team_id = state.team_id
    agent_name = to_string(state.name)

    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      Checkpoints.delete_agent_checkpoints(team_id, agent_name)
    end)
  end
end
