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

  @doc "Share a discovery via the context topic."
  def broadcast_context(team_id, %{from: from} = payload) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "team:#{team_id}:context",
      {:context_update, from, payload}
    )
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
