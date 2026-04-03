defmodule Loomkin.Decisions.Broadcaster do
  @moduledoc "Per-team GenServer that watches for new observations/outcomes and notifies agents with relevant active goals."

  use GenServer

  require Logger

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms

  @debounce_ms 5_000

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:broadcaster, team_id}}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    Loomkin.Signals.subscribe("decision.node.added")

    state = %{
      team_id: team_id,
      recent_notifications: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    if signal_team_id == nil or signal_team_id == state.team_id do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(%Jido.Signal{type: "decision.node.added", data: data}, state) do
    node = Map.get(data, :node)

    if node && relevant_node?(node, state.team_id) do
      state = safe_process_node(node, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp safe_process_node(node, state) do
    process_node(node, state)
  rescue
    e ->
      Logger.error(
        "[Kin:broadcaster] process_node failed for #{node.id}: #{Exception.message(e)}"
      )

      state
  end

  defp relevant_node?(node, team_id) do
    node.node_type in [:observation, :outcome] and
      get_in(node.metadata, ["team_id"]) == team_id
  end

  defp process_node(node, state) do
    ancestors = Graph.walk_upstream(node.id, [:enables, :requires, :leads_to], max_depth: 3)

    active_goals =
      Enum.filter(ancestors, fn {ancestor, _depth, _edge_type} ->
        ancestor.node_type == :goal and ancestor.status == :active
      end)

    now = System.monotonic_time(:millisecond)
    state = expire_stale_notifications(state, now)

    Enum.reduce(active_goals, state, fn {goal, _depth, _edge_type}, acc ->
      agent_name = goal.agent_name

      if agent_name && not debounced?(acc, goal.id, agent_name, now) do
        payload = %{
          observation_id: node.id,
          observation_title: node.title,
          goal_id: goal.id,
          goal_title: goal.title,
          keeper_id: get_in(node.metadata, ["keeper_id"]),
          source_agent: node.agent_name
        }

        Comms.send_to(acc.team_id, agent_name, {:discovery_relevant, payload})

        mark_notified(acc, goal.id, agent_name, now)
      else
        acc
      end
    end)
  end

  defp debounced?(state, goal_id, agent_name, now) do
    case Map.get(state.recent_notifications, {goal_id, agent_name}) do
      nil -> false
      last_time -> now - last_time < @debounce_ms
    end
  end

  defp mark_notified(state, goal_id, agent_name, now) do
    %{
      state
      | recent_notifications: Map.put(state.recent_notifications, {goal_id, agent_name}, now)
    }
  end

  defp expire_stale_notifications(state, now) do
    cleaned =
      Map.reject(state.recent_notifications, fn {_key, timestamp} ->
        now - timestamp > @debounce_ms * 2
      end)

    %{state | recent_notifications: cleaned}
  end
end
