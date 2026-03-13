defmodule Loomkin.Teams.Topics do
  @moduledoc """
  Centralized topic string generation for Jido Signal Bus paths and Phoenix PubSub topics.

  All signal topic strings used throughout the application should be generated
  by this module rather than using raw string interpolation. This ensures
  consistency and makes it easy to audit or refactor topic naming.

  ## Jido Signal Bus paths

  Glob-style paths used with `Loomkin.Signals.subscribe/2`:
  - `*` matches exactly one segment
  - `**` matches one or more segments

  ## Phoenix PubSub topics

  Colon-delimited topics used with `Phoenix.PubSub.subscribe/2`.
  """

  # -- Jido Signal Bus glob paths (subscribe to all signals in a domain) --

  @doc "Matches all agent signals (e.g. agent.stream.agent-1, agent.status.idle)."
  def agent_all, do: "agent.**"

  @doc "Matches all team signals (e.g. team.task.assigned, team.dissolved)."
  def team_all, do: "team.**"

  @doc "Matches all context signals (e.g. context.update)."
  def context_all, do: "context.**"

  @doc "Matches all decision signals (e.g. decision.logged)."
  def decision_all, do: "decision.**"

  @doc "Matches all channel signals."
  def channel_all, do: "channel.**"

  @doc "Matches all collaboration signals (e.g. collaboration.peer.message)."
  def collaboration_all, do: "collaboration.**"

  @doc "Matches all system signals."
  def system_all, do: "system.**"

  @doc "Matches all session signals."
  def session_all, do: "session.**"

  # -- Per-entity paths --

  @doc "Path for a specific agent's stream (e.g. `agent.stream.agent-1`)."
  def agent_stream(agent_id), do: "agent.stream.#{agent_id}"

  @doc "Matches all collaboration vote signals."
  def collaboration_vote_all, do: "collaboration.vote.*"

  # -- Phoenix PubSub topics --

  @doc "Phoenix PubSub topic for a specific team (e.g. `team:abc123`)."
  def team_pubsub(team_id), do: "team:#{team_id}"

  # -- Convenience --

  @doc """
  Returns all top-level glob paths for bulk subscription to the Jido Signal Bus.

  Does not include `system.**` as system signals are typically subscribed to
  separately by infrastructure processes.
  """
  def global_bus_paths do
    [
      agent_all(),
      team_all(),
      context_all(),
      decision_all(),
      channel_all(),
      collaboration_all(),
      session_all()
    ]
  end
end
