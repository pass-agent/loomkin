defmodule Loomkin.Decisions.Broadcaster do
  @moduledoc "Per-team GenServer that watches for new observations/outcomes and notifies agents with relevant active goals."

  use GenServer

  require Logger

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms

  @pubsub Loomkin.PubSub
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

    Phoenix.PubSub.subscribe(@pubsub, "decision_graph")

    state = %{
      team_id: team_id,
      # %{{goal_id, agent_name} => timestamp} for debouncing
      recent_notifications: %{}
    }

    Logger.info("[Broadcaster] Started for team #{team_id}")
    {:ok, state}
  end

  @impl true
  def handle_info({:node_added, node}, state) do
    if relevant_node?(node, state.team_id) do
      state = process_node(node, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

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

        Logger.debug(
          "[Broadcaster] Notified #{agent_name} about #{node.node_type} #{node.id} → goal #{goal.id}"
        )

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
