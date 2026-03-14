defmodule Loomkin.Teams.Debate do
  @moduledoc """
  Orchestrates structured multi-agent debate within a team.

  Runs a propose -> critique -> revise -> vote cycle across participants,
  logging proposals and critiques to the decision graph. Not a GenServer —
  coordinates via existing agent infrastructure and `Comms`.

  When a `ConsensusPolicy` is provided, the debate uses policy-driven
  convergence tracking, early-stop on quorum, and deadlock detection.
  Without a policy, falls back to the default policy behavior.
  """

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.ConsensusPolicy
  alias Loomkin.Teams.ConsensusTrail

  @default_max_rounds 3
  @default_round_timeout_ms 30_000

  # Convergence: if top-choice weight % changes by less than this between rounds,
  # the round is considered "stalled" for oscillation detection.
  @convergence_epsilon 2.0

  # Number of consecutive stalled rounds required to declare oscillation/deadlock.
  @oscillation_window 3

  @type vote_map :: %{optional(String.t()) => String.t()}
  @type round_data :: %{
          round: pos_integer(),
          proposals: [map()],
          critiques: [map()],
          revisions: [map()],
          convergence: map() | nil
        }
  @type outcome :: :consensus_reached | :deadlock | :escalated | :rounds_exhausted
  @type debate_result :: %{
          winner: map() | nil,
          votes: vote_map(),
          rounds: [round_data()],
          consensus?: boolean(),
          outcome: outcome(),
          rationale: String.t()
        }

  @doc """
  Initiate a structured debate among participants on a given topic.

  ## Options

    * `:max_rounds` - maximum number of debate rounds (default #{@default_max_rounds})
    * `:round_timeout_ms` - timeout per round phase in ms (default #{@default_round_timeout_ms})
    * `:session_id` - optional session ID for decision graph nodes
    * `:policy` - a `%ConsensusPolicy{}` struct controlling quorum, scope, and deadlock strategy.
      Defaults to `ConsensusPolicy.default()`.

  Returns `{:ok, debate_result}` or `{:error, reason}`.
  """
  @spec initiate_debate(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, debate_result()} | {:error, atom()}
  def initiate_debate(team_id, topic, participants, opts \\ [])

  def initiate_debate(_team_id, _topic, participants, _opts)
      when length(participants) < 2 do
    {:error, :insufficient_participants}
  end

  def initiate_debate(team_id, topic, participants, opts) do
    policy = Keyword.get(opts, :policy, ConsensusPolicy.default())
    max_rounds = Keyword.get(opts, :max_rounds, config_max_rounds(policy))
    round_timeout = Keyword.get(opts, :round_timeout_ms, config_round_timeout())
    session_id = Keyword.get(opts, :session_id)

    debate_id = Ecto.UUID.generate()

    # Subscribe the current process to debate responses for this debate
    Loomkin.Signals.subscribe("collaboration.debate.response")

    # Notify participants that a debate has started
    Enum.each(participants, fn participant ->
      Comms.send_to(team_id, participant, {:debate_start, debate_id, topic, participants})
    end)

    # Run rounds with convergence tracking and possible early-stop
    {rounds, early_stop_reason} =
      run_rounds_with_convergence(
        team_id,
        debate_id,
        topic,
        participants,
        max_rounds,
        round_timeout,
        session_id,
        policy
      )

    result =
      tally_and_build_result(
        team_id,
        debate_id,
        topic,
        participants,
        rounds,
        round_timeout,
        session_id,
        policy,
        early_stop_reason
      )

    {:ok, result}
  end

  # -- Round execution with convergence tracking --

  defp run_rounds_with_convergence(
         team_id,
         debate_id,
         topic,
         participants,
         max_rounds,
         timeout,
         session_id,
         policy
       ) do
    Enum.reduce_while(1..max_rounds, {[], nil}, fn round_num, {rounds_acc, _} ->
      {:ok, round_data} =
        run_round(team_id, debate_id, topic, participants, round_num, timeout, session_id)

      # Compute convergence snapshot for this round
      convergence =
        compute_round_convergence(team_id, round_data, rounds_acc, participants, policy.scope)

      round_data = Map.put(round_data, :convergence, convergence)

      # Log round summary with convergence delta
      ConsensusTrail.log_round_summary(
        debate_id,
        round_num,
        round_data,
        session_id,
        convergence[:delta]
      )

      rounds_acc = rounds_acc ++ [round_data]

      cond do
        # Early-stop: all participants converged on same position
        convergence.quorum_met ->
          {:halt, {rounds_acc, :quorum_reached}}

        # Oscillation/deadlock: positions not converging
        detect_oscillation(rounds_acc) ->
          {:halt, {rounds_acc, :oscillation_detected}}

        true ->
          {:cont, {rounds_acc, nil}}
      end
    end)
  end

  defp run_round(team_id, debate_id, topic, participants, round_num, timeout, session_id) do
    # Phase 1: Propose
    Enum.each(participants, fn participant ->
      Comms.send_to(team_id, participant, {:debate_propose, debate_id, round_num, topic})
    end)

    proposals = collect_responses(debate_id, :proposal, participants, timeout)

    # Normalize into structured format (backward-compat: plain text still works)
    proposals = Enum.map(proposals, &normalize_proposal/1)

    # Log proposals to decision graph
    proposal_nodes =
      Enum.map(proposals, fn proposal ->
        {:ok, node} =
          Graph.add_node(%{
            node_type: :option,
            title: "Debate proposal: #{truncate(proposal.content, 80)}",
            description: proposal.content,
            confidence: proposal[:confidence] || 50,
            agent_name: proposal.from,
            session_id: session_id,
            metadata: %{
              debate_id: debate_id,
              round: round_num,
              phase: "proposal",
              structured: Map.has_key?(proposal, :approach)
            }
          })

        Comms.broadcast_decision(team_id, node.id, proposal.from)
        Map.put(proposal, :node_id, node.id)
      end)

    # Phase 2: Critique — each participant critiques others' proposals
    Enum.each(participants, fn participant ->
      others = Enum.reject(proposal_nodes, &(&1.from == participant))

      Comms.send_to(team_id, participant, {
        :debate_critique,
        debate_id,
        round_num,
        others
      })
    end)

    critiques = collect_responses(debate_id, :critique, participants, timeout)

    # Log critiques to decision graph
    Enum.each(critiques, fn critique ->
      {:ok, node} =
        Graph.add_node(%{
          node_type: :observation,
          title: "Critique by #{critique.from}",
          description: critique.content,
          confidence: critique[:confidence] || 50,
          agent_name: critique.from,
          session_id: session_id,
          metadata: %{debate_id: debate_id, round: round_num, phase: "critique"}
        })

      # Link critique to the proposal it targets
      if critique[:target_node_id] do
        Graph.add_edge(node.id, critique.target_node_id, :supports,
          rationale: "critique of proposal"
        )
      end

      Comms.broadcast_decision(team_id, node.id, critique.from)
    end)

    # Phase 3: Revise — participants may revise their proposals based on critiques
    Enum.each(participants, fn participant ->
      my_critiques = Enum.filter(critiques, &(&1[:target] == participant))

      Comms.send_to(team_id, participant, {
        :debate_revise,
        debate_id,
        round_num,
        my_critiques
      })
    end)

    revisions = collect_responses(debate_id, :revision, participants, timeout)

    # Normalize revisions into structured format
    revisions = Enum.map(revisions, &normalize_proposal/1)

    # Log revision artifacts to decision graph
    logged_revisions = ConsensusTrail.log_revisions(revisions, debate_id, round_num, session_id)

    round_data = %{
      round: round_num,
      proposals: proposal_nodes,
      critiques: critiques,
      revisions: logged_revisions
    }

    {:ok, round_data}
  end

  # -- Voting & result --

  defp tally_and_build_result(
         team_id,
         debate_id,
         topic,
         participants,
         rounds,
         timeout,
         session_id,
         policy,
         early_stop_reason
       ) do
    # Request votes from all participants
    final_proposals = build_final_proposals(rounds)

    Enum.each(participants, fn participant ->
      Comms.send_to(team_id, participant, {:debate_vote, debate_id, final_proposals})
    end)

    votes = collect_responses(debate_id, :vote, participants, timeout)
    vote_map = Map.new(votes, fn v -> {v.from, v.choice} end)

    # Get agent info for weighted voting
    agents = Loomkin.Teams.Context.list_agents(team_id)

    # Use weighted tallying with policy scope
    weighted = tally_weighted_votes(votes, agents, topic, policy.scope)

    # Find the winning proposal by weighted winner
    winner_id = weighted.winner

    winner =
      Enum.find(final_proposals, fn p ->
        p.from == winner_id || p[:node_id] == winner_id
      end)

    # Check consensus using policy quorum
    quorum_met? =
      ConsensusPolicy.quorum_met?(
        policy.quorum,
        weighted.winning_weight_pct,
        length(votes),
        length(participants)
      )

    # Determine explicit outcome state
    {outcome, rationale} =
      determine_outcome(weighted, quorum_met?, early_stop_reason, rounds)

    # Apply deadlock strategy if needed
    {winner, outcome, rationale} =
      apply_deadlock_strategy(winner, outcome, rationale, policy, final_proposals)

    consensus? = outcome == :consensus_reached

    # Log the final outcome via ConsensusTrail
    trail_attrs = %{
      debate_id: debate_id,
      topic: topic,
      winner: winner,
      consensus?: consensus?,
      quorum_met?: quorum_met?,
      policy: policy,
      weighted: weighted,
      vote_map: vote_map,
      session_id: session_id,
      rounds: rounds,
      deadlock_reason: unless(consensus?, do: rationale)
    }

    ConsensusTrail.log_outcome(trail_attrs)

    # Emit collaboration events based on outcome
    if consensus? do
      ConsensusTrail.emit_consensus_success(
        team_id,
        debate_id,
        winner,
        policy,
        %{
          weighted_tallies: weighted.weighted_tallies,
          rounds_completed: length(rounds),
          outcome: outcome,
          rationale: rationale
        }
      )
    else
      # Build escalation payload for deadlocked debates
      escalation_payload = ConsensusTrail.build_escalation_payload(trail_attrs)
      competing = escalation_payload.competing_options

      ConsensusTrail.emit_consensus_deadlock(
        team_id,
        debate_id,
        competing,
        %{
          rounds_completed: length(rounds),
          policy: inspect(policy.quorum),
          outcome: outcome,
          rationale: rationale
        }
      )

      if outcome == :escalated do
        ConsensusTrail.emit_consensus_escalation(team_id, debate_id, escalation_payload)
      end
    end

    %{
      winner: winner,
      votes: vote_map,
      rounds: rounds,
      consensus?: consensus?,
      outcome: outcome,
      rationale: rationale,
      policy: policy,
      weighted_tallies: weighted.weighted_tallies,
      vote_weights: weighted.vote_weights
    }
  end

  # -- Outcome determination --

  defp determine_outcome(weighted, quorum_met?, early_stop_reason, rounds) do
    cond do
      # Quorum met via final vote
      quorum_met? ->
        {:consensus_reached,
         "Consensus reached with #{Float.round(weighted.winning_weight_pct, 1)}% weighted support"}

      # Early stop due to quorum reached during rounds (positions fully converged)
      early_stop_reason == :quorum_reached ->
        {:consensus_reached,
         "Consensus reached via early-stop after #{length(rounds)} round(s) — positions fully converged"}

      # Early stop due to oscillation
      early_stop_reason == :oscillation_detected ->
        {:deadlock,
         "Deadlock detected: positions oscillated without convergence over #{length(rounds)} rounds"}

      # All rounds exhausted without consensus
      true ->
        {:rounds_exhausted,
         "Completed #{length(rounds)} rounds without consensus " <>
           "(#{Float.round(weighted.winning_weight_pct, 1)}% weighted support for winner)"}
    end
  end

  # -- Deadlock strategy --

  defp apply_deadlock_strategy(
         winner,
         outcome,
         rationale,
         %ConsensusPolicy{} = policy,
         final_proposals
       )
       when outcome in [:deadlock, :rounds_exhausted] do
    case policy.on_deadlock do
      :leader_decides ->
        resolved_winner = winner || Enum.at(final_proposals, 0)
        {resolved_winner, outcome, rationale <> "; resolved by leader_decides policy"}

      :random_tiebreak ->
        chosen =
          if final_proposals == [], do: winner, else: Enum.random(final_proposals)

        suffix = if chosen, do: " (chose #{chosen.from}'s proposal)", else: ""
        {chosen, outcome, rationale <> "; resolved by random_tiebreak policy" <> suffix}

      :escalate_to_user ->
        {winner, :escalated, rationale <> "; escalating to user per policy"}
    end
  end

  defp apply_deadlock_strategy(winner, outcome, rationale, _policy, _proposals) do
    {winner, outcome, rationale}
  end

  # -- Structured Proposal Parsing --

  @doc """
  Normalize a proposal/revision response into the structured contract.

  Accepts both structured maps (with `:approach`, `:scores`, `:tradeoffs`,
  `:confidence`) and plain-text maps (with only `:content`). Plain-text
  proposals are wrapped with default fields for backward compatibility.
  """
  @spec normalize_proposal(map()) :: map()
  def normalize_proposal(%{approach: _} = proposal) do
    # Already structured — ensure all expected keys exist
    proposal
    |> Map.put_new(:scores, %{})
    |> Map.put_new(:tradeoffs, [])
    |> Map.put_new(:confidence, 50)
    |> ensure_content_from_approach()
  end

  def normalize_proposal(%{content: content} = proposal) when is_binary(content) do
    # Plain-text fallback — try to parse structured data from text
    case try_parse_structured(content) do
      {:ok, structured} ->
        Map.merge(proposal, structured)

      :plain ->
        proposal
        |> Map.put_new(:confidence, 50)
    end
  end

  def normalize_proposal(%{from: from} = proposal) do
    proposal
    |> Map.put_new(:content, "#{from}'s proposal")
    |> Map.put_new(:confidence, 50)
  end

  def normalize_proposal(proposal), do: Map.put_new(proposal, :confidence, 50)

  defp ensure_content_from_approach(%{content: _} = p), do: p
  defp ensure_content_from_approach(%{approach: approach} = p), do: Map.put(p, :content, approach)

  defp try_parse_structured(text) do
    trimmed = String.trim(text)

    cond do
      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, %{"approach" => approach} = parsed} ->
            {:ok,
             %{
               approach: approach,
               scores: Map.get(parsed, "scores", %{}),
               tradeoffs: Map.get(parsed, "tradeoffs", []),
               confidence: Map.get(parsed, "confidence", 50),
               content: approach
             }}

          _ ->
            :plain
        end

      true ->
        :plain
    end
  end

  # Extract a position key for convergence tracking.
  # Uses the approach field if structured, otherwise uses the content.
  defp extract_position_key(%{approach: approach}) when is_binary(approach), do: approach

  defp extract_position_key(%{content: content}) when is_binary(content) do
    String.slice(content, 0, 100)
  end

  defp extract_position_key(_), do: "unknown"

  # -- Convergence tracking --

  @doc false
  def compute_round_convergence(team_id, round_data, prior_rounds, participants, scope) do
    agents = Loomkin.Teams.Context.list_agents(team_id)

    # Use revisions if available, otherwise proposals
    current_positions =
      if round_data.revisions != [] do
        round_data.revisions
      else
        round_data.proposals
      end

    # Build position summary: which approach each participant is advocating
    position_map =
      Map.new(current_positions, fn p ->
        {p.from, extract_position_key(p)}
      end)

    # Count how many agree on the same position
    position_groups = Enum.group_by(position_map, fn {_from, pos} -> pos end)

    largest_group_size =
      position_groups
      |> Enum.map(fn {_pos, members} -> length(members) end)
      |> Enum.max(fn -> 0 end)

    total = length(participants)
    agreement_pct = if total > 0, do: largest_group_size / total * 100.0, else: 0.0

    # Simulate a "round vote" using position alignment for weighted convergence
    simulated_votes =
      Enum.map(current_positions, fn p ->
        %{
          from: p.from,
          choice: extract_position_key(p),
          confidence: (p[:confidence] || 50) / 100.0
        }
      end)

    weighted =
      if simulated_votes != [] do
        tally_weighted_votes(simulated_votes, agents, "", scope)
      else
        %{winning_weight_pct: 0.0, consensus?: false}
      end

    # Previous round's top position percentage
    prior_top_pct =
      case List.last(prior_rounds) do
        nil -> 0.0
        prev -> get_in(prev, [:convergence, :weighted_top_pct]) || 0.0
      end

    delta = weighted.winning_weight_pct - prior_top_pct

    %{
      agreement_pct: agreement_pct,
      weighted_top_pct: weighted.winning_weight_pct,
      unique_positions: map_size(position_groups),
      delta: delta,
      position_groups: Map.new(position_groups, fn {pos, members} -> {pos, length(members)} end),
      quorum_met: agreement_pct >= 100.0 and length(current_positions) == total and total > 0,
      stalled: abs(delta) < @convergence_epsilon and length(prior_rounds) > 0
    }
  end

  # Detect oscillation: if the last N rounds all have stalled convergence
  # (top position percentage not changing), it's oscillating/deadlocked.
  defp detect_oscillation(rounds) when length(rounds) < @oscillation_window, do: false

  defp detect_oscillation(rounds) do
    last_n = Enum.take(rounds, -@oscillation_window)

    Enum.all?(last_n, fn round ->
      convergence = round[:convergence] || %{}
      convergence[:stalled] == true
    end)
  end

  # -- Helpers --

  defp collect_responses(debate_id, phase, participants, timeout) do
    expected = MapSet.new(participants)

    do_collect(debate_id, phase, expected, MapSet.new(), [], timeout)
  end

  defp do_collect(_debate_id, _phase, expected, received, acc, _timeout)
       when expected == received do
    acc
  end

  defp do_collect(debate_id, phase, expected, received, acc, timeout) do
    receive do
      {:signal,
       %Jido.Signal{
         type: "collaboration.debate.response",
         data: %{debate_id: ^debate_id, phase: ^phase, response: response}
       }} ->
        from = response.from

        if MapSet.member?(expected, from) and not MapSet.member?(received, from) do
          do_collect(
            debate_id,
            phase,
            expected,
            MapSet.put(received, from),
            acc ++ [response],
            timeout
          )
        else
          do_collect(debate_id, phase, expected, received, acc, timeout)
        end
    after
      timeout ->
        # Return whatever we've collected so far
        acc
    end
  end

  defp build_final_proposals(rounds) do
    case List.last(rounds) do
      nil ->
        []

      last_round ->
        # Use revisions if available, otherwise original proposals
        if last_round.revisions != [] do
          last_round.revisions
        else
          last_round.proposals
        end
    end
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."

  # -- Weighted Voting --

  @doc """
  Calculate the expertise weight for a given agent role and decision topic/scope.

  Returns a float between 0.5 and 2.0 representing how relevant the agent's
  role is to the decision scope. Higher weight = more expertise.

  ## Examples

      iex> Debate.expertise_weight(:coder, "code")
      2.0

      iex> Debate.expertise_weight(:researcher, "code")
      1.0
  """
  @spec expertise_weight(atom(), String.t()) :: float()
  def expertise_weight(role, scope) when is_atom(role) and is_binary(scope) do
    scope = String.downcase(scope)

    role_strengths = %{
      lead: ~w(architecture planning coordination general),
      coder: ~w(code implementation refactoring debugging),
      researcher: ~w(research analysis investigation codebase),
      reviewer: ~w(code review quality security),
      tester: ~w(testing validation quality)
    }

    strengths = Map.get(role_strengths, role, [])

    cond do
      scope in strengths -> 2.0
      scope == "general" -> 1.0
      partial_match?(strengths, scope) -> 1.5
      true -> 0.5
    end
  end

  def expertise_weight(_role, _scope), do: 1.0

  defp partial_match?(strengths, scope) do
    Enum.any?(strengths, fn s ->
      String.contains?(scope, s) or String.contains?(s, scope)
    end)
  end

  @doc """
  Compute the overall vote weight for an agent.

  Combines three factors:
  - Role expertise weight (0.5-2.0) based on role vs decision scope
  - Capability score (0.0-1.0) from agent info, defaults to 0.5
  - Stated confidence (0.0-1.0) from the vote itself, defaults to 0.5

  Final weight = expertise * (0.5 + 0.25 * capability + 0.25 * confidence)
  """
  @spec compute_vote_weight(map(), atom(), String.t(), float()) :: float()
  def compute_vote_weight(agent_info, role, scope, stated_confidence \\ 0.5) do
    expertise = expertise_weight(role, scope)
    capability = Map.get(agent_info, :capability_score, 0.5)
    confidence = clamp(stated_confidence, 0.0, 1.0)

    expertise * (0.5 + 0.25 * capability + 0.25 * confidence)
  end

  @doc """
  Tally votes with weights. Returns a result map with raw tallies, weighted
  tallies, per-agent weights, winner, and consensus flag.

  ## Parameters
  - `votes` — list of `%{from: name, choice: option, confidence: 0.0..1.0}`
  - `agents` — list of agent info maps `%{name: _, role: _, ...}`
  - `topic` — the decision topic string
  - `scope` — the decision scope for expertise weighting
  """
  @spec tally_weighted_votes([map()], [map()], String.t(), String.t()) :: map()
  def tally_weighted_votes(votes, agents, _topic, scope) do
    agent_map = Map.new(agents, fn a -> {to_string(a.name), a} end)

    # Compute per-voter weight
    vote_weights =
      Map.new(votes, fn vote ->
        from = to_string(vote.from)
        agent = Map.get(agent_map, from, %{role: :coder})
        role = agent[:role] || :coder
        confidence = vote[:confidence] || 0.5

        {from, compute_vote_weight(agent, role, scope, confidence)}
      end)

    # Raw tallies (simple count)
    raw_tallies =
      Enum.reduce(votes, %{}, fn vote, acc ->
        choice = to_string(vote.choice)
        Map.update(acc, choice, 1, &(&1 + 1))
      end)

    # Weighted tallies
    weighted_tallies =
      Enum.reduce(votes, %{}, fn vote, acc ->
        choice = to_string(vote.choice)
        from = to_string(vote.from)
        weight = Map.get(vote_weights, from, 1.0)
        Map.update(acc, choice, weight, &(&1 + weight))
      end)

    # Determine winner by weighted tally
    {winner, winning_weight} =
      if weighted_tallies == %{} do
        {nil, 0.0}
      else
        Enum.max_by(weighted_tallies, fn {_k, v} -> v end)
      end

    total_weight = Enum.reduce(weighted_tallies, 0.0, fn {_k, v}, acc -> acc + v end)

    winning_weight_pct =
      if total_weight > 0, do: winning_weight / total_weight * 100, else: 0.0

    unique_choices = Map.keys(weighted_tallies)
    consensus? = length(unique_choices) <= 1 and length(votes) > 0

    %{
      winner: winner,
      raw_tallies: raw_tallies,
      weighted_tallies: weighted_tallies,
      vote_weights: vote_weights,
      consensus?: consensus?,
      winning_weight_pct: winning_weight_pct
    }
  end

  defp clamp(val, min, max), do: val |> Kernel.max(min) |> Kernel.min(max)

  @doc """
  Submit a debate response from a participant.

  Called by agents (or tools) to submit their response to a debate phase.
  Broadcasts on the debate PubSub topic so the orchestrator can collect it.
  """
  @spec submit_response(String.t(), String.t(), atom(), map()) :: :ok
  def submit_response(team_id, debate_id, phase, response) do
    signal =
      Loomkin.Signals.Collaboration.DebateResponse.new!(
        %{debate_id: debate_id, team_id: team_id, phase: phase},
        subject: debate_id
      )

    Loomkin.Signals.publish(%{signal | data: Map.merge(signal.data, %{response: response})})
  end

  # --- Config helpers ---

  defp config_max_rounds(policy) do
    config_nested([:teams, :debate, :max_rounds], nil) || policy.max_rounds || @default_max_rounds
  end

  defp config_round_timeout do
    config_nested([:teams, :debate, :round_timeout_ms], @default_round_timeout_ms)
  end

  defp config_nested(key_path, default) do
    get_in(Loomkin.Config.all(), key_path) || default
  end
end
