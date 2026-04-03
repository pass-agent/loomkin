defmodule Loomkin.Teams.ConsensusTrail do
  @moduledoc """
  Records consensus outcomes to the decision graph and emits collaboration events.

  Provides:
  - Revision artifact logging (links revised proposals to originals via :revises edges)
  - Round summary nodes with convergence metadata
  - Final outcome nodes with policy/quorum/deadlock context
  - Escalation payload construction for user intervention
  - Collaboration event emission for consensus success, deadlock, and escalation
  """

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.CollaborationEvents
  alias Loomkin.Teams.ConsensusPolicy

  @type escalation_payload :: %{
          debate_id: String.t(),
          topic: String.t(),
          competing_options: [%{agent: String.t(), content: String.t(), weighted_score: float()}],
          criteria_scores: %{String.t() => float()},
          key_tradeoffs: [%{option_a: String.t(), option_b: String.t(), tradeoff: String.t()}],
          convergence_trend: [float()],
          suggested_next_action: atom(),
          policy_used: String.t(),
          rounds_completed: non_neg_integer()
        }

  # --- Revision Artifacts ---

  @doc """
  Log revision nodes to the decision graph, linking them back to original proposals
  via `:revises` edges.

  For each revision that has an `:original_node_id`, creates:
  - An `:option` node with `phase: "revision"` metadata
  - A `:revises` edge from the revision node to the original proposal node
  """
  @spec log_revisions(list(), String.t(), non_neg_integer(), String.t() | nil) :: list()
  def log_revisions(revisions, debate_id, round_num, session_id) do
    Enum.map(revisions, fn revision ->
      {:ok, node} =
        Graph.add_node(%{
          node_type: :option,
          title: "Revision by #{revision.from}: #{truncate(revision.content, 60)}",
          description: revision.content,
          confidence: revision[:confidence] || 55,
          agent_name: revision.from,
          session_id: session_id,
          metadata: %{
            "debate_id" => debate_id,
            "round" => round_num,
            "phase" => "revision"
          }
        })

      # Link revision to original proposal
      if revision[:original_node_id] do
        Graph.add_edge(node.id, revision.original_node_id, :revises,
          rationale: "revised proposal after critique"
        )
      end

      Map.put(revision, :node_id, node.id)
    end)
  end

  # --- Round Summaries ---

  @doc """
  Log a round summary node capturing convergence metadata.

  Creates an `:outcome` node with metadata including participant count,
  proposal/critique/revision counts, and an optional convergence delta.
  """
  @spec log_round_summary(String.t(), non_neg_integer(), map(), String.t() | nil, float() | nil) ::
          {:ok, Loomkin.Schemas.DecisionNode.t()}
  def log_round_summary(debate_id, round_num, round_data, session_id, convergence_delta \\ nil) do
    proposal_count = length(round_data.proposals)
    critique_count = length(round_data.critiques)
    revision_count = length(round_data.revisions)

    metadata = %{
      "debate_id" => debate_id,
      "round" => round_num,
      "phase" => "round_summary",
      "proposal_count" => proposal_count,
      "critique_count" => critique_count,
      "revision_count" => revision_count
    }

    metadata =
      if convergence_delta do
        Map.put(metadata, "convergence_delta", convergence_delta)
      else
        metadata
      end

    Graph.add_node(%{
      node_type: :outcome,
      title: "Round #{round_num} summary",
      description:
        "#{proposal_count} proposals, #{critique_count} critiques, #{revision_count} revisions",
      confidence: nil,
      session_id: session_id,
      metadata: metadata
    })
  end

  # --- Final Outcome ---

  @doc """
  Log the final debate outcome node with rich policy and quorum metadata.

  Creates a `:decision` node recording:
  - Policy used (quorum mode, scope, deadlock strategy)
  - Quorum target and actual achieved
  - Convergence trend across rounds
  - Final outcome status (consensus, deadlock, or escalation)
  - Deadlock reason if applicable
  """
  @spec log_outcome(map()) :: {:ok, Loomkin.Schemas.DecisionNode.t()} | {:error, term()}
  def log_outcome(attrs) do
    %{
      debate_id: debate_id,
      topic: topic,
      winner: winner,
      consensus?: consensus?,
      policy: policy,
      weighted: weighted,
      vote_map: vote_map,
      session_id: session_id,
      rounds: rounds
    } = attrs

    quorum_met? = Map.get(attrs, :quorum_met?, consensus?)
    deadlock_reason = Map.get(attrs, :deadlock_reason)

    final_outcome =
      cond do
        consensus? and quorum_met? -> "consensus"
        not quorum_met? and policy.on_deadlock == :escalate_to_user -> "escalation"
        true -> "deadlock"
      end

    convergence_trend = compute_convergence_trend(rounds)

    title =
      case final_outcome do
        "consensus" ->
          winner_label = if winner, do: truncate(winner.content, 60), else: "agreed"
          "Consensus: #{winner_label}"

        "deadlock" ->
          "Deadlock after #{length(rounds)} rounds"

        "escalation" ->
          "Escalated to user after #{length(rounds)} rounds"
      end

    confidence =
      case final_outcome do
        "consensus" -> 90
        "deadlock" -> round(weighted.winning_weight_pct)
        "escalation" -> round(weighted.winning_weight_pct)
      end

    {:ok, node} =
      Graph.add_node(%{
        node_type: :decision,
        title: title,
        description: topic,
        confidence: confidence,
        agent_name: if(winner, do: winner.from),
        session_id: session_id,
        metadata: %{
          "debate_id" => debate_id,
          "final_outcome" => final_outcome,
          "policy_used" => inspect_policy(policy),
          "quorum_target" => to_string(policy.quorum),
          "quorum_met" => quorum_met?,
          "convergence_trend" => convergence_trend,
          "deadlock_reason" => deadlock_reason,
          "votes" => vote_map,
          "weighted_tallies" => weighted.weighted_tallies,
          "vote_weights" => weighted.vote_weights,
          "rounds_completed" => length(rounds)
        }
      })

    # Link winner proposal to outcome node
    if winner && winner[:node_id] do
      Graph.add_edge(winner.node_id, node.id, :leads_to,
        rationale: "selected by #{final_outcome}"
      )
    end

    {:ok, node}
  end

  # --- Collaboration Events ---

  @doc """
  Emit a consensus success collaboration event.
  """
  @spec emit_consensus_success(String.t(), String.t(), map() | nil, ConsensusPolicy.t(), map()) ::
          :ok
  def emit_consensus_success(team_id, debate_id, winner, policy, metadata) do
    CollaborationEvents.consensus_success(
      team_id,
      debate_id,
      winner,
      policy,
      metadata
    )
  end

  @doc """
  Emit a consensus deadlock collaboration event.
  """
  @spec emit_consensus_deadlock(String.t(), String.t(), [map()], map()) :: :ok
  def emit_consensus_deadlock(team_id, debate_id, competing_options, metadata) do
    CollaborationEvents.consensus_deadlock(
      team_id,
      debate_id,
      competing_options,
      metadata
    )
  end

  @doc """
  Emit a consensus escalation collaboration event with the escalation payload.
  """
  @spec emit_consensus_escalation(String.t(), String.t(), escalation_payload()) :: :ok
  def emit_consensus_escalation(team_id, debate_id, escalation_payload) do
    CollaborationEvents.consensus_escalation(
      team_id,
      debate_id,
      escalation_payload
    )
  end

  # --- Escalation Payload ---

  @doc """
  Build a structured escalation payload for user intervention.

  The payload contains all information needed for a human to make an informed
  decision: competing options with scores, key tradeoffs, convergence history,
  and a suggested next action.
  """
  @spec build_escalation_payload(map()) :: escalation_payload()
  def build_escalation_payload(attrs) do
    %{
      debate_id: debate_id,
      topic: topic,
      policy: policy,
      weighted: weighted,
      rounds: rounds
    } = attrs

    competing = build_competing_options(weighted)
    criteria = build_criteria_scores(weighted)
    tradeoffs = build_tradeoffs(competing)
    trend = compute_convergence_trend(rounds)
    suggested = suggest_next_action(weighted, rounds, policy)

    %{
      debate_id: debate_id,
      topic: topic,
      competing_options: competing,
      criteria_scores: criteria,
      key_tradeoffs: tradeoffs,
      convergence_trend: trend,
      suggested_next_action: suggested,
      policy_used: inspect_policy(policy),
      rounds_completed: length(rounds)
    }
  end

  # --- Private Helpers ---

  defp build_competing_options(weighted) do
    weighted.weighted_tallies
    |> Enum.sort_by(fn {_option, score} -> score end, :desc)
    |> Enum.map(fn {option, score} ->
      %{
        agent: option,
        content: option,
        weighted_score: Float.round(score * 1.0, 2)
      }
    end)
  end

  defp build_criteria_scores(weighted) do
    total = Enum.reduce(weighted.weighted_tallies, 0.0, fn {_k, v}, acc -> acc + v end)

    if total > 0 do
      Map.new(weighted.weighted_tallies, fn {option, score} ->
        {option, Float.round(score / total * 100, 1)}
      end)
    else
      %{}
    end
  end

  defp build_tradeoffs(competing) when length(competing) < 2, do: []

  defp build_tradeoffs(competing) do
    competing
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      diff = Float.round(abs(a.weighted_score - b.weighted_score), 2)

      %{
        option_a: a.agent,
        option_b: b.agent,
        tradeoff:
          "Score difference: #{diff} (#{a.agent}: #{a.weighted_score} vs #{b.agent}: #{b.weighted_score})"
      }
    end)
  end

  defp compute_convergence_trend(rounds) do
    rounds
    |> Enum.map(fn round ->
      proposals = round.proposals || []
      revisions = round.revisions || []
      proposal_count = length(proposals)

      if proposal_count > 0 do
        Float.round(length(revisions) / proposal_count * 100, 1)
      else
        0.0
      end
    end)
  end

  defp suggest_next_action(weighted, rounds, _policy) do
    spread = compute_vote_spread(weighted)
    rounds_used = length(rounds)

    cond do
      # Very close vote — try a revote with narrowed options
      spread < 10.0 -> :revote
      # Large spread — the leading option is clear, defer to team lead
      spread > 60.0 -> :defer_to_lead
      # Multiple rounds already used — try narrowing scope
      rounds_used >= 3 -> :narrow_scope
      # Default — split the task if approaches differ
      true -> :split_task
    end
  end

  defp compute_vote_spread(weighted) do
    scores = Map.values(weighted.weighted_tallies)

    case scores do
      [] ->
        0.0

      [_] ->
        100.0

      _ ->
        sorted = Enum.sort(scores, :desc)
        total = Enum.sum(sorted)
        if total > 0, do: (hd(sorted) - List.last(sorted)) / total * 100, else: 0.0
    end
  end

  defp inspect_policy(%ConsensusPolicy{} = p) do
    "quorum=#{p.quorum}, max_rounds=#{p.max_rounds}, scope=#{p.scope}, on_deadlock=#{p.on_deadlock}"
  end

  defp inspect_policy(_), do: "default"

  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(nil, _max), do: ""
  defp truncate(other, max), do: truncate(to_string(other), max)
end
