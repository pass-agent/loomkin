defmodule Loomkin.Teams.CollaborationEvents do
  @moduledoc "Emit standardized collaboration events for the activity feed."

  alias Loomkin.Teams.CollaborationMetrics
  alias Loomkin.Teams.Comms

  @type collab_event :: %{
          type: atom(),
          agents: [String.t()],
          description: String.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @doc "Broadcast when an agent shares a discovery with teammates."
  def discovery_shared(team_id, from_agent, to_agents, discovery_type) do
    to_list = List.wrap(to_agents)

    broadcast_collab(team_id, %{
      type: :discovery_shared,
      agents: [from_agent | to_list],
      description:
        "#{from_agent} shared a #{discovery_type} discovery with #{format_agents(to_list)}",
      metadata: %{from: from_agent, to: to_list, discovery_type: discovery_type}
    })
  end

  @doc "Broadcast when an agent asks another agent a question."
  def question_asked(team_id, from_agent, to_agent, question) do
    truncated = String.slice(to_string(question), 0, 200)

    broadcast_collab(team_id, %{
      type: :question_asked,
      agents: [from_agent, to_agent],
      description: "#{from_agent} asked #{to_agent}: #{truncated}",
      metadata: %{from: from_agent, to: to_agent, question: truncated}
    })
  end

  @doc "Broadcast when an agent answers a previously asked question."
  def question_answered(team_id, from_agent, to_agent, query_id) do
    broadcast_collab(team_id, %{
      type: :question_answered,
      agents: [from_agent, to_agent],
      description: "#{from_agent} answered #{to_agent}'s question",
      metadata: %{from: from_agent, to: to_agent, query_id: query_id}
    })
  end

  @doc "Broadcast when a task is reassigned from one agent to another."
  def task_rebalanced(team_id, task_id, from_agent, to_agent) do
    broadcast_collab(team_id, %{
      type: :task_rebalanced,
      agents: [from_agent, to_agent],
      description: "Task reassigned from #{from_agent} to #{to_agent}",
      metadata: %{task_id: task_id, from: from_agent, to: to_agent}
    })
  end

  @doc "Broadcast when a conflict is detected between two agents."
  def conflict_detected(team_id, agent_a, agent_b, conflict_type) do
    broadcast_collab(team_id, %{
      type: :conflict_detected,
      agents: [agent_a, agent_b],
      description: "Conflict detected between #{agent_a} and #{agent_b}: #{conflict_type}",
      metadata: %{agent_a: agent_a, agent_b: agent_b, conflict_type: conflict_type}
    })
  end

  @doc "Broadcast when the team reaches consensus on a decision."
  def consensus_reached(team_id, decision, weighted_score) do
    score_str = Float.round(weighted_score / 1, 2) |> to_string()

    broadcast_collab(team_id, %{
      type: :consensus_reached,
      agents: [],
      description: "Team voted: #{decision} (weighted score: #{score_str})",
      metadata: %{decision: decision, weighted_score: weighted_score}
    })
  end

  @doc "Broadcast when a debate reaches consensus successfully."
  def consensus_success(team_id, debate_id, winner, policy, metadata) do
    winner_label =
      cond do
        is_map(winner) and is_binary(winner[:content]) -> String.slice(winner.content, 0, 80)
        is_map(winner) and is_binary(winner[:from]) -> "#{winner.from}'s proposal"
        true -> "team decision"
      end

    policy_label = if is_binary(policy_name(policy)), do: " (#{policy_name(policy)})", else: ""

    broadcast_collab(team_id, %{
      type: :consensus_success,
      agents: if(is_map(winner), do: [winner[:from] || "system"], else: []),
      description: "Consensus reached: #{winner_label}#{policy_label}",
      metadata:
        Map.merge(metadata || %{}, %{
          debate_id: debate_id,
          winner:
            if(is_map(winner), do: Map.take(winner, [:from, :content, :node_id]), else: nil),
          policy: policy_name(policy)
        })
    })
  end

  @doc "Broadcast when a debate ends in deadlock (no consensus)."
  def consensus_deadlock(team_id, debate_id, competing_options, metadata) do
    option_count = length(competing_options)
    top_options = Enum.take(competing_options, 2)

    labels =
      Enum.map(top_options, fn opt ->
        agent = opt[:agent] || "unknown"
        score = opt[:weighted_score] || 0.0
        "#{agent} (#{Float.round(score / 1, 1)})"
      end)

    broadcast_collab(team_id, %{
      type: :consensus_deadlock,
      agents: Enum.map(competing_options, & &1[:agent]) |> Enum.reject(&is_nil/1),
      description: "Deadlock: #{option_count} competing options — #{Enum.join(labels, " vs ")}",
      metadata:
        Map.merge(metadata || %{}, %{
          debate_id: debate_id,
          competing_options: competing_options
        })
    })
  end

  @doc "Broadcast when a deadlocked debate is escalated for user intervention."
  def consensus_escalation(team_id, debate_id, escalation_payload) do
    action = escalation_payload[:suggested_next_action] || :unknown

    broadcast_collab(team_id, %{
      type: :consensus_escalation,
      agents: [],
      description: "Escalated to user — suggested action: #{action}",
      metadata: %{
        debate_id: debate_id,
        escalation_payload: escalation_payload
      }
    })
  end

  @doc "Broadcast when knowledge propagates from a sub-team to a parent team."
  def knowledge_propagated(team_id, source_team_id, discovery_type) do
    broadcast_collab(team_id, %{
      type: :knowledge_propagated,
      agents: [],
      description:
        "Discovery (#{discovery_type}) propagated from sub-team #{String.slice(source_team_id, 0, 12)}",
      metadata: %{source_team_id: source_team_id, discovery_type: discovery_type}
    })
  end

  # -- Private --

  defp broadcast_collab(team_id, payload) do
    event = Map.put(payload, :timestamp, DateTime.utc_now())
    # Record metrics backend-side (not in LiveView) so counts are accurate
    # regardless of connected UI clients
    CollaborationMetrics.record_event(team_id, payload.type)
    Comms.broadcast(team_id, {:collab_event, event})
  end

  defp policy_name(%{quorum: q}), do: "#{q}"
  defp policy_name(_), do: nil

  defp format_agents([]), do: "the team"
  defp format_agents([single]), do: single
  defp format_agents([a, b]), do: "#{a} and #{b}"

  defp format_agents(agents) do
    {init, [last]} = Enum.split(agents, -1)
    Enum.join(init, ", ") <> ", and " <> last
  end
end
