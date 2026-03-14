defmodule Loomkin.Decisions.AutoLogger do
  @moduledoc "Per-team GenServer that subscribes to team signals and writes decision graph nodes."

  use GenServer

  require Logger

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Tasks

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
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

    state = %{
      team_id: team_id,
      seen_agents: MapSet.new(),
      task_nodes: %{}
    }

    {:ok, state}
  end

  @impl true
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

      log_node(state, %{
        node_type: :action,
        title: "Agent #{name} joined team",
        agent_name: to_string(name)
      })

      {:noreply, state}
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
      require Logger

      Logger.warning(
        "[Kin:data] auto_logger task.assigned missing fields: agent_name=#{inspect(agent_name)} task_id=#{inspect(task_id)}"
      )
    end

    case log_node(state, %{
           node_type: :action,
           title: "Task assigned: #{title} -> #{agent_name}",
           agent_name: to_string(agent_name),
           metadata: base_metadata(state, %{"task_id" => task_id})
         }) do
      {:ok, node} ->
        state = put_in(state.task_nodes[task_id], node.id)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Task completed
  def handle_info(%Jido.Signal{type: "team.task.completed", data: data}, state) do
    task_id = data.task_id
    owner = data.owner
    title = task_title(task_id)

    case log_node(state, %{
           node_type: :outcome,
           title: "Completed: #{title}",
           agent_name: to_string(owner),
           metadata: base_metadata(state, %{"task_id" => task_id})
         }) do
      {:ok, node} ->
        if parent_id = state.task_nodes[task_id] do
          safe_add_edge(parent_id, node.id, :leads_to)
        end

        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # Task failed
  def handle_info(%Jido.Signal{type: "team.task.failed", data: data}, state) do
    task_id = data.task_id
    owner = data.owner
    reason = Map.get(data, :reason, "unknown")
    title = task_title(task_id)

    case log_node(state, %{
           node_type: :outcome,
           title: "Failed: #{title} -- #{truncate(inspect(reason), 120)}",
           agent_name: to_string(owner),
           metadata: base_metadata(state, %{"task_id" => task_id})
         }) do
      {:ok, node} ->
        if parent_id = state.task_nodes[task_id] do
          safe_add_edge(parent_id, node.id, :leads_to)
        end

        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # Keeper created (context offloaded)
  def handle_info(%Jido.Signal{type: "context.keeper.created", data: data}, state) do
    log_node(state, %{
      node_type: :observation,
      title: "Context offloaded: #{data.topic}",
      agent_name: to_string(data.source),
      metadata: base_metadata(state, %{"keeper_id" => data.id})
    })

    {:noreply, state}
  end

  # Skip context offloaded (redundant with keeper_created)
  def handle_info(%Jido.Signal{type: "context.offloaded"}, state) do
    {:noreply, state}
  end

  # Tool executing
  def handle_info(
        %Jido.Signal{type: "agent.tool.executing", data: data},
        state
      ) do
    agent_name = to_string(data.agent_name)
    tool_name = get_in(data, [:payload, :tool_name]) || "unknown"

    log_node(state, %{
      node_type: :action,
      title: "Tool: #{tool_name} (#{agent_name})",
      agent_name: agent_name,
      metadata: base_metadata(state, %{"tool_name" => tool_name})
    })

    {:noreply, state}
  end

  # Tool complete
  def handle_info(
        %Jido.Signal{type: "agent.tool.complete", data: data},
        state
      ) do
    agent_name = to_string(data.agent_name)
    tool_name = get_in(data, [:payload, :tool_name]) || "unknown"

    log_node(state, %{
      node_type: :outcome,
      title: "Tool done: #{tool_name} (#{agent_name})",
      agent_name: agent_name,
      metadata: base_metadata(state, %{"tool_name" => tool_name})
    })

    {:noreply, state}
  end

  # Agent error
  def handle_info(%Jido.Signal{type: "agent.error", data: data}, state) do
    agent_name = data |> Map.get(:agent_name, "unknown") |> to_string()
    reason = Map.get(data, :reason, "unknown")

    log_node(state, %{
      node_type: :outcome,
      title: "Error (#{agent_name}): #{truncate(inspect(reason), 120)}",
      agent_name: agent_name,
      metadata: base_metadata(state, %{"error" => true})
    })

    {:noreply, state}
  end

  # Agent escalation
  def handle_info(%Jido.Signal{type: "agent.escalation", data: data}, state) do
    agent_name = to_string(data.agent_name)
    from_model = Map.get(data, :from_model, "?")
    to_model = Map.get(data, :to_model, "?")

    log_node(state, %{
      node_type: :revisit,
      title: "Escalated #{agent_name}: #{from_model} -> #{to_model}",
      agent_name: agent_name,
      metadata: base_metadata(state, %{"from_model" => from_model, "to_model" => to_model})
    })

    {:noreply, state}
  end

  # Task started
  def handle_info(%Jido.Signal{type: "team.task.started", data: data}, state) do
    task_id = data.task_id
    owner = to_string(data.owner)
    title = task_title(task_id)

    case log_node(state, %{
           node_type: :action,
           title: "Started: #{title} (#{owner})",
           agent_name: owner,
           metadata: base_metadata(state, %{"task_id" => task_id})
         }) do
      {:ok, node} ->
        if parent_id = state.task_nodes[task_id] do
          safe_add_edge(parent_id, node.id, :leads_to)
        end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Peer message
  def handle_info(%Jido.Signal{type: "collaboration.peer.message", data: data}, state) do
    from = to_string(data.from)
    message = Map.get(data, :message, "")

    log_node(state, %{
      node_type: :observation,
      title: "Peer msg from #{from}: #{truncate(inspect(message), 100)}",
      agent_name: from,
      metadata: base_metadata(state)
    })

    {:noreply, state}
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

    log_node(state, %{
      node_type: :decision,
      title: "Debate response from #{from}",
      agent_name: to_string(from),
      metadata: base_metadata(state, %{"debate_id" => debate_id})
    })

    {:noreply, state}
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp log_node(state, attrs) do
    attrs =
      attrs
      |> Map.put_new(:metadata, base_metadata(state))
      |> Map.update!(:metadata, &Map.merge(base_metadata(state), &1))

    try do
      case Graph.add_node(attrs) do
        {:ok, node} = result ->
          link_to_active_goal(node, state.team_id)
          result

        {:error, _reason} = error ->
          error
      end
    catch
      kind, reason ->
        Logger.debug(
          "[Kin:auto_logger] decision logging unavailable: #{inspect(kind)} #{inspect(reason)}"
        )

        {:error, :db_unavailable}
    end
  end

  defp link_to_active_goal(node, team_id) do
    if node.node_type in [:action, :observation] do
      case Graph.list_nodes(node_type: :goal, status: :active, team_id: team_id) do
        [] ->
          :ok

        goals ->
          goal = List.last(goals)
          Graph.add_edge(goal.id, node.id, :leads_to)
      end
    end
  end

  defp safe_add_edge(from_id, to_id, label) do
    Graph.add_edge(from_id, to_id, label)
  catch
    kind, reason ->
      Logger.debug(
        "[Kin:auto_logger] edge logging unavailable: #{inspect(kind)} #{inspect(reason)}"
      )

      {:error, :db_unavailable}
  end

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
