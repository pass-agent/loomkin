defmodule Loomkin.Teams.Comms do
  @moduledoc "Convenience functions wrapping Phoenix.PubSub for team communication."

  @pubsub Loomkin.PubSub

  @doc "Subscribe agent to all team topics."
  def subscribe(team_id, agent_name) do
    for topic <- topics(team_id, agent_name) do
      Phoenix.PubSub.subscribe(@pubsub, topic)
    end

    :ok
  end

  @doc "Unsubscribe agent from all team topics."
  def unsubscribe(team_id, agent_name) do
    for topic <- topics(team_id, agent_name) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic)
    end

    :ok
  end

  @doc "Send a direct message to a specific agent."
  def send_to(team_id, agent_name, message) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "team:#{team_id}:agent:#{agent_name}",
      message
    )
  end

  @doc "Broadcast a message to the entire team."
  def broadcast(team_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}", message)
  end

  @doc """
  Share a discovery via the context topic.

  ## Options

    * `:propagate_up` - if true, also broadcast to parent team for `:insight` and
      `:blocker` type discoveries. Defaults to `true`.

  """
  def broadcast_context(team_id, %{from: from} = payload, opts \\ []) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "team:#{team_id}:context",
      {:context_update, from, payload}
    )

    propagate_up = Keyword.get(opts, :propagate_up, true)

    if propagate_up do
      maybe_propagate_to_parent(team_id, payload)
    end

    :ok
  end

  @doc """
  Broadcast a discovery only to agents whose relevance score exceeds the threshold.

  Falls back to full broadcast if no agents are registered or scoring fails.
  """
  def broadcast_context_targeted(team_id, %{from: from} = payload, threshold \\ 0.3) do
    alias Loomkin.Teams.Context
    alias Loomkin.Teams.RelevanceScorer

    agents = Context.list_agents(team_id)

    if agents == [] do
      # No agents registered — fall back to topic broadcast
      broadcast_context(team_id, payload)
    else
      relevant =
        agents
        |> Enum.reject(fn agent -> to_string(agent.name) == to_string(from) end)
        |> RelevanceScorer.filter_relevant(payload, threshold)

      if relevant == [] do
        # No relevant agents found — still broadcast on topic so it's not lost
        broadcast_context(team_id, payload)
      else
        # Send targeted messages to relevant agents only
        Enum.each(relevant, fn {agent, _score} ->
          send_to(team_id, agent.name, {:context_update, from, payload})
        end)
      end
    end
  end

  @doc "Broadcast a task event (assigned, completed, etc)."
  def broadcast_task_event(team_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, "team:#{team_id}:tasks", event)
  end

  @doc "Broadcast a decision graph change."
  def broadcast_decision(team_id, node_id, agent_name) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "team:#{team_id}:decisions",
      {:decision_logged, node_id, agent_name}
    )
  end

  # -- Private --

  @propagatable_types ~w[insight blocker]

  defp maybe_propagate_to_parent(team_id, %{from: from} = payload) do
    type = to_string(payload[:type] || "")

    if type in @propagatable_types do
      case Loomkin.Teams.Manager.get_parent_team(team_id) do
        {:ok, parent_team_id} ->
          propagated = Map.put(payload, :source_team, team_id)

          Phoenix.PubSub.broadcast(
            @pubsub,
            "team:#{parent_team_id}:context",
            {:context_update, from, propagated}
          )

        :none ->
          :ok
      end
    end
  end

  defp topics(team_id, agent_name) do
    [
      "team:#{team_id}",
      "team:#{team_id}:agent:#{agent_name}",
      "team:#{team_id}:context",
      "team:#{team_id}:tasks",
      "team:#{team_id}:decisions"
    ]
  end
end
