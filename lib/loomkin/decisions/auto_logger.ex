defmodule Loomkin.Decisions.AutoLogger do
  @moduledoc "Per-team GenServer that subscribes to team signals and writes decision graph nodes."

  use GenServer

  require Logger

  alias Loomkin.Decisions.Graph
  alias Loomkin.Repo
  alias Loomkin.Schemas.DecisionEdge
  alias Loomkin.Schemas.DecisionNode
  alias Loomkin.Teams.Tasks

  # Read-only reconnaissance tools that don't represent meaningful decisions.
  # These are completely skipped to reduce decision graph noise.
  @low_value_tools ~w(
    directory_list
    file_read
    file_search
    content_search
    decision_query
    query_backlog
    search_keepers
    list_teams
    cross_team_query
    introspect_decision_history
    introspect_failure_patterns
    team_progress
    lsp_diagnostics
    context_retrieve
    load_skill
    peer_discovery
  )

  # Tools completing under this threshold get a single combined node
  # instead of separate action + outcome nodes.
  @fast_tool_threshold_ms 1_000

  # Flush buffer when it exceeds this many entries
  @buffer_flush_threshold 20

  # Timer interval for periodic flush (ms)
  @flush_interval_ms 3_000

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  def flush(pid) do
    GenServer.call(pid, :flush)
  end

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:auto_logger, team_id}}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    Loomkin.Signals.subscribe("agent.status")
    Loomkin.Signals.subscribe("team.task.*")
    Loomkin.Signals.subscribe("context.keeper.created")
    Loomkin.Signals.subscribe("context.offloaded")
    Loomkin.Signals.subscribe("agent.tool.*")
    Loomkin.Signals.subscribe("agent.error")
    Loomkin.Signals.subscribe("agent.escalation")
    Loomkin.Signals.subscribe("collaboration.peer.message")
    Loomkin.Signals.subscribe("decision.logged")
    Loomkin.Signals.subscribe("collaboration.debate.response")

    timer_ref = Process.send_after(self(), :flush_buffer, @flush_interval_ms)

    state = %{
      team_id: team_id,
      seen_agents: MapSet.new(),
      task_nodes: %{},
      pending_tools: %{},
      pending_nodes: [],
      pending_edges: [],
      goal_links: [],
      flush_timer: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    state = do_flush(state)
    timer_ref = Process.send_after(self(), :flush_buffer, @flush_interval_ms)
    {:noreply, %{state | flush_timer: timer_ref}}
  end

  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    if signal_for_team?(sig, state.team_id) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  # Agent joins (first time only)
  def handle_info(
        %Jido.Signal{type: "agent.status", data: %{agent_name: name, status: :working}},
        state
      ) do
    if MapSet.member?(state.seen_agents, name) do
      {:noreply, state}
    else
      state = %{state | seen_agents: MapSet.put(state.seen_agents, name)}

      state =
        buffer_node(state, %{
          node_type: :action,
          title: "Agent #{name} joined team",
          agent_name: to_string(name)
        })

      {:noreply, maybe_flush(state)}
    end
  end

  # Ignore other agent status events
  def handle_info(%Jido.Signal{type: "agent.status"}, state) do
    {:noreply, state}
  end

  # Task assigned
  def handle_info(%Jido.Signal{type: "team.task.assigned", data: data}, state) do
    task_id = data.task_id
    agent_name = data.agent_name
    title = task_title(task_id)

    if is_nil(agent_name) or is_nil(task_id) do
      Logger.warning(
        "[Kin:data] auto_logger task.assigned missing fields: agent_name=#{inspect(agent_name)} task_id=#{inspect(task_id)}"
      )
    end

    {node_id, state} =
      buffer_node_with_id(state, %{
        node_type: :action,
        title: "Task assigned: #{title} -> #{agent_name}",
        agent_name: to_string(agent_name),
        metadata: base_metadata(state, %{"task_id" => task_id})
      })

    state = put_in(state.task_nodes[task_id], node_id)
    {:noreply, maybe_flush(state)}
  end

  # Task completed
  def handle_info(%Jido.Signal{type: "team.task.completed", data: data}, state) do
    task_id = data.task_id
    owner = data.owner
    title = task_title(task_id)

    {node_id, state} =
      buffer_node_with_id(state, %{
        node_type: :outcome,
        title: "Completed: #{title}",
        agent_name: to_string(owner),
        metadata: base_metadata(state, %{"task_id" => task_id})
      })

    state =
      if parent_id = state.task_nodes[task_id] do
        buffer_edge(state, parent_id, node_id, :leads_to)
      else
        state
      end

    {:noreply, maybe_flush(state)}
  end

  # Task failed
  def handle_info(%Jido.Signal{type: "team.task.failed", data: data}, state) do
    task_id = data.task_id
    owner = data.owner
    reason = Map.get(data, :reason, "unknown")
    title = task_title(task_id)

    {node_id, state} =
      buffer_node_with_id(state, %{
        node_type: :outcome,
        title: "Failed: #{title} -- #{truncate(inspect(reason), 120)}",
        agent_name: to_string(owner),
        metadata: base_metadata(state, %{"task_id" => task_id})
      })

    state =
      if parent_id = state.task_nodes[task_id] do
        buffer_edge(state, parent_id, node_id, :leads_to)
      else
        state
      end

    {:noreply, maybe_flush(state)}
  end

  # Keeper created (context offloaded)
  def handle_info(%Jido.Signal{type: "context.keeper.created", data: data}, state) do
    state =
      buffer_node(state, %{
        node_type: :observation,
        title: "Context offloaded: #{data.topic}",
        agent_name: to_string(data.source),
        metadata: base_metadata(state, %{"keeper_id" => data.id})
      })

    {:noreply, maybe_flush(state)}
  end

  # Skip context offloaded (redundant with keeper_created)
  def handle_info(%Jido.Signal{type: "context.offloaded"}, state) do
    {:noreply, state}
  end

  # Tool executing — skip low-value tools, defer action node for others
  def handle_info(
        %Jido.Signal{type: "agent.tool.executing", data: data},
        state
      ) do
    tool_name = get_in(data, [:payload, :tool_name]) || "unknown"

    if tool_name in @low_value_tools do
      {:noreply, state}
    else
      agent_name = to_string(data.agent_name)
      tool_key = {agent_name, tool_name}

      state =
        put_in(
          state.pending_tools[tool_key],
          System.monotonic_time(:millisecond)
        )

      {:noreply, state}
    end
  end

  # Tool complete — skip low-value tools, collapse fast tools into single node
  def handle_info(
        %Jido.Signal{type: "agent.tool.complete", data: data},
        state
      ) do
    tool_name = get_in(data, [:payload, :tool_name]) || "unknown"

    if tool_name in @low_value_tools do
      {:noreply, state}
    else
      agent_name = to_string(data.agent_name)
      tool_key = {agent_name, tool_name}

      {started_at, state} = pop_in(state.pending_tools[tool_key])
      elapsed = if started_at, do: System.monotonic_time(:millisecond) - started_at, else: nil

      state =
        if elapsed && elapsed < @fast_tool_threshold_ms do
          buffer_node(state, %{
            node_type: :action,
            title: "Tool: #{tool_name} (#{agent_name}) [done]",
            agent_name: agent_name,
            metadata: base_metadata(state, %{"tool_name" => tool_name, "elapsed_ms" => elapsed})
          })
        else
          {action_id, state} =
            buffer_node_with_id(state, %{
              node_type: :action,
              title: "Tool: #{tool_name} (#{agent_name})",
              agent_name: agent_name,
              metadata: base_metadata(state, %{"tool_name" => tool_name})
            })

          {outcome_id, state} =
            buffer_node_with_id(state, %{
              node_type: :outcome,
              title: "Tool done: #{tool_name} (#{agent_name})",
              agent_name: agent_name,
              metadata: base_metadata(state, %{"tool_name" => tool_name})
            })

          buffer_edge(state, action_id, outcome_id, :leads_to)
        end

      {:noreply, maybe_flush(state)}
    end
  end

  # Agent error
  def handle_info(%Jido.Signal{type: "agent.error", data: data}, state) do
    agent_name = data |> Map.get(:agent_name, "unknown") |> to_string()
    reason = Map.get(data, :reason, "unknown")

    state =
      buffer_node(state, %{
        node_type: :outcome,
        title: "Error (#{agent_name}): #{truncate(inspect(reason), 120)}",
        agent_name: agent_name,
        metadata: base_metadata(state, %{"error" => true})
      })

    {:noreply, maybe_flush(state)}
  end

  # Agent escalation
  def handle_info(%Jido.Signal{type: "agent.escalation", data: data}, state) do
    agent_name = to_string(data.agent_name)
    from_model = Map.get(data, :from_model, "?")
    to_model = Map.get(data, :to_model, "?")

    state =
      buffer_node(state, %{
        node_type: :revisit,
        title: "Escalated #{agent_name}: #{from_model} -> #{to_model}",
        agent_name: agent_name,
        metadata: base_metadata(state, %{"from_model" => from_model, "to_model" => to_model})
      })

    {:noreply, maybe_flush(state)}
  end

  # Task started
  def handle_info(%Jido.Signal{type: "team.task.started", data: data}, state) do
    task_id = data.task_id
    owner = to_string(data.owner)
    title = task_title(task_id)

    {node_id, state} =
      buffer_node_with_id(state, %{
        node_type: :action,
        title: "Started: #{title} (#{owner})",
        agent_name: owner,
        metadata: base_metadata(state, %{"task_id" => task_id})
      })

    state =
      if parent_id = state.task_nodes[task_id] do
        buffer_edge(state, parent_id, node_id, :leads_to)
      else
        state
      end

    {:noreply, maybe_flush(state)}
  end

  # Peer message
  def handle_info(%Jido.Signal{type: "collaboration.peer.message", data: data}, state) do
    from = to_string(data.from)
    message = Map.get(data, :message, "")

    state =
      buffer_node(state, %{
        node_type: :observation,
        title: "Peer msg from #{from}: #{truncate(inspect(message), 100)}",
        agent_name: from,
        metadata: base_metadata(state)
      })

    {:noreply, maybe_flush(state)}
  end

  # Decision logged — re-emit as decision.node.added (already handled by Graph.add_node)
  def handle_info(%Jido.Signal{type: "decision.logged"}, state) do
    # decision.logged signals come from manual logging (Comms.broadcast_decision).
    # The node already exists in the graph, so no new node needed here.
    {:noreply, state}
  end

  # Debate response
  def handle_info(%Jido.Signal{type: "collaboration.debate.response", data: data}, state) do
    debate_id = data.debate_id
    response = Map.get(data, :response, %{})
    from = Map.get(response, :from, "unknown")

    state =
      buffer_node(state, %{
        node_type: :decision,
        title: "Debate response from #{from}",
        agent_name: to_string(from),
        metadata: base_metadata(state, %{"debate_id" => debate_id})
      })

    {:noreply, maybe_flush(state)}
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  # --- Private helpers: buffering ---

  defp buffer_node(state, attrs) do
    {_id, state} = buffer_node_with_id(state, attrs)
    state
  end

  defp buffer_node_with_id(state, attrs) do
    node_id = Ecto.UUID.generate()

    attrs =
      attrs
      |> Map.put_new(:metadata, base_metadata(state))
      |> Map.update!(:metadata, &Map.merge(base_metadata(state), &1))

    node_type = attrs[:node_type]

    entry = %{
      id: node_id,
      node_type: node_type,
      title: attrs[:title],
      description: attrs[:description],
      status: attrs[:status] || :active,
      confidence: attrs[:confidence],
      metadata: attrs[:metadata],
      agent_name: attrs[:agent_name],
      session_id: attrs[:session_id],
      change_id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(:second),
      updated_at: DateTime.utc_now(:second)
    }

    # Track goal links for action/observation nodes
    goal_links =
      if node_type in [:action, :observation] do
        [{node_id, state.team_id} | state.goal_links]
      else
        state.goal_links
      end

    state = %{
      state
      | pending_nodes: [entry | state.pending_nodes],
        goal_links: goal_links
    }

    {node_id, state}
  end

  defp buffer_edge(state, from_id, to_id, edge_type) do
    entry = %{
      from_node_id: from_id,
      to_node_id: to_id,
      edge_type: edge_type,
      change_id: Ecto.UUID.generate(),
      weight: 1.0,
      rationale: nil,
      inserted_at: DateTime.utc_now(:second),
      updated_at: DateTime.utc_now(:second)
    }

    %{state | pending_edges: [entry | state.pending_edges]}
  end

  defp maybe_flush(state) do
    if length(state.pending_nodes) + length(state.pending_edges) >= @buffer_flush_threshold do
      do_flush(state)
    else
      state
    end
  end

  defp do_flush(%{pending_nodes: [], pending_edges: [], goal_links: []} = state), do: state

  defp do_flush(state) do
    nodes = Enum.reverse(state.pending_nodes)
    edges = Enum.reverse(state.pending_edges)
    goal_links = Enum.reverse(state.goal_links)

    try do
      if nodes != [] do
        Repo.insert_all(DecisionNode, nodes)

        # Publish signals for each inserted node (matches Graph.add_node behaviour)
        for entry <- nodes do
          team_id = get_in(entry, [:metadata, "team_id"])
          signal = Loomkin.Signals.Decision.NodeAdded.new!(%{team_id: team_id || ""})

          node_data = struct(DecisionNode, entry)
          Loomkin.Signals.publish(%{signal | data: Map.put(signal.data, :node, node_data)})
        end
      end

      # Resolve goal links — look up active goals and create edges
      goal_edges =
        Enum.flat_map(goal_links, fn {node_id, team_id} ->
          case Graph.list_nodes(node_type: :goal, status: :active, team_id: team_id) do
            [] ->
              []

            goals ->
              goal = List.last(goals)

              [
                %{
                  from_node_id: goal.id,
                  to_node_id: node_id,
                  edge_type: :leads_to,
                  change_id: Ecto.UUID.generate(),
                  weight: 1.0,
                  rationale: nil,
                  inserted_at: DateTime.utc_now(:second),
                  updated_at: DateTime.utc_now(:second)
                }
              ]
          end
        end)

      all_edges = edges ++ goal_edges

      if all_edges != [] do
        Repo.insert_all(DecisionEdge, all_edges)
      end
    catch
      kind, reason ->
        Logger.debug("[Kin:auto_logger] batch flush failed: #{inspect(kind)} #{inspect(reason)}")
    end

    %{state | pending_nodes: [], pending_edges: [], goal_links: []}
  end

  # --- Private helpers ---

  defp base_metadata(state, extra \\ %{}) do
    Map.merge(%{"auto_logged" => true, "team_id" => state.team_id}, extra)
  end

  defp task_title(task_id) do
    case Tasks.get_task(task_id) do
      {:ok, task} -> task.title
      _ -> task_id
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp signal_for_team?(sig, team_id) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_team_id == nil or signal_team_id == team_id
  end
end
