defmodule Loomkin.Teams.ConsensusTrailTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ConsensusTrail, ConsensusPolicy, Manager, Debate}
  alias Loomkin.Decisions.Graph

  setup do
    {:ok, team_id} = Manager.create_team(name: "trail-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  # --- Revision Artifacts ---

  describe "log_revisions/4" do
    test "creates option nodes for revisions with revision metadata" do
      debate_id = Ecto.UUID.generate()

      revisions = [
        %{from: "alice", content: "Revised approach: use GenServer", confidence: 70},
        %{from: "bob", content: "Revised approach: use Agent", confidence: 65}
      ]

      logged = ConsensusTrail.log_revisions(revisions, debate_id, 2, nil)

      assert length(logged) == 2
      assert Enum.all?(logged, &Map.has_key?(&1, :node_id))

      # Verify nodes in decision graph
      nodes = Graph.list_nodes(node_type: :option)

      revision_nodes =
        Enum.filter(nodes, fn n ->
          n.metadata["debate_id"] == debate_id and n.metadata["phase"] == "revision"
        end)

      assert length(revision_nodes) == 2
      assert Enum.all?(revision_nodes, &(&1.metadata["round"] == 2))
    end

    test "creates :revises edge when original_node_id is present" do
      debate_id = Ecto.UUID.generate()

      # Create an original proposal node first
      {:ok, original} =
        Graph.add_node(%{
          node_type: :option,
          title: "Original proposal",
          description: "Use ETS",
          metadata: %{debate_id: debate_id, round: 1, phase: "proposal"}
        })

      revisions = [
        %{
          from: "alice",
          content: "Revised: use ETS with backup",
          original_node_id: original.id
        }
      ]

      [logged] = ConsensusTrail.log_revisions(revisions, debate_id, 2, nil)

      # Verify :revises edge exists
      edges = Graph.list_edges(edge_type: :revises)
      assert length(edges) >= 1

      revises_edge =
        Enum.find(edges, fn e ->
          e.from_node_id == logged.node_id and e.to_node_id == original.id
        end)

      assert revises_edge != nil
      assert revises_edge.rationale == "revised proposal after critique"
    end

    test "skips edge when no original_node_id" do
      debate_id = Ecto.UUID.generate()

      revisions = [%{from: "alice", content: "A new idea"}]

      [logged] = ConsensusTrail.log_revisions(revisions, debate_id, 1, nil)
      assert logged.node_id

      # No :revises edges should be created for this revision
      edges = Graph.list_edges(edge_type: :revises)

      related =
        Enum.filter(edges, fn e -> e.from_node_id == logged.node_id end)

      assert related == []
    end
  end

  # --- Round Summaries ---

  describe "log_round_summary/5" do
    test "creates an outcome node with round metadata" do
      debate_id = Ecto.UUID.generate()

      round_data = %{
        proposals: [%{from: "alice"}, %{from: "bob"}],
        critiques: [%{from: "bob"}],
        revisions: [%{from: "alice"}]
      }

      {:ok, node} = ConsensusTrail.log_round_summary(debate_id, 1, round_data, nil)

      assert node.node_type == :outcome
      assert node.title == "Round 1 summary"
      assert node.metadata["debate_id"] == debate_id
      assert node.metadata["round"] == 1
      assert node.metadata["phase"] == "round_summary"
      assert node.metadata["proposal_count"] == 2
      assert node.metadata["critique_count"] == 1
      assert node.metadata["revision_count"] == 1
    end

    test "includes convergence_delta when provided" do
      debate_id = Ecto.UUID.generate()

      round_data = %{proposals: [], critiques: [], revisions: []}

      {:ok, node} = ConsensusTrail.log_round_summary(debate_id, 2, round_data, nil, 15.5)

      assert node.metadata["convergence_delta"] == 15.5
    end
  end

  # --- Final Outcome ---

  describe "log_outcome/1" do
    test "creates a decision node for consensus outcome" do
      debate_id = Ecto.UUID.generate()
      policy = ConsensusPolicy.default()

      winner = %{from: "alice", content: "Use GenServer", node_id: nil}

      weighted = %{
        winner: "alice",
        winning_weight_pct: 75.0,
        weighted_tallies: %{"alice" => 2.5, "bob" => 0.8},
        vote_weights: %{"alice" => 1.0, "bob" => 0.8}
      }

      attrs = %{
        debate_id: debate_id,
        topic: "Architecture choice",
        winner: winner,
        consensus?: true,
        quorum_met?: true,
        policy: policy,
        weighted: weighted,
        vote_map: %{"alice" => "alice", "bob" => "alice"},
        session_id: nil,
        rounds: [%{proposals: [%{from: "alice"}], critiques: [], revisions: []}]
      }

      {:ok, node} = ConsensusTrail.log_outcome(attrs)

      assert node.node_type == :decision
      assert node.title =~ "Consensus"
      assert node.confidence == 90
      assert node.metadata["final_outcome"] == "consensus"
      assert node.metadata["quorum_met"] == true
      assert node.metadata["debate_id"] == debate_id
      assert node.metadata["rounds_completed"] == 1
      assert is_list(node.metadata["convergence_trend"])
    end

    test "creates a decision node for deadlock outcome" do
      debate_id = Ecto.UUID.generate()

      {:ok, policy} =
        ConsensusPolicy.new(quorum: :majority, on_deadlock: :leader_decides)

      weighted = %{
        winner: "alice",
        winning_weight_pct: 45.0,
        weighted_tallies: %{"alice" => 1.5, "bob" => 1.2},
        vote_weights: %{"alice" => 1.0, "bob" => 0.8}
      }

      attrs = %{
        debate_id: debate_id,
        topic: "Framework choice",
        winner: %{from: "alice", content: "Phoenix"},
        consensus?: false,
        quorum_met?: false,
        policy: policy,
        weighted: weighted,
        vote_map: %{"alice" => "alice", "bob" => "bob"},
        session_id: nil,
        rounds:
          [%{proposals: [%{}], critiques: [], revisions: []}]
          |> List.duplicate(3)
          |> List.flatten()
      }

      {:ok, node} = ConsensusTrail.log_outcome(attrs)

      assert node.metadata["final_outcome"] == "deadlock"
      assert node.title =~ "Deadlock"
      assert node.confidence == 45
    end

    test "creates an escalation outcome when policy says escalate_to_user" do
      debate_id = Ecto.UUID.generate()
      policy = ConsensusPolicy.default()

      weighted = %{
        winner: "alice",
        winning_weight_pct: 45.0,
        weighted_tallies: %{"alice" => 1.5, "bob" => 1.2},
        vote_weights: %{"alice" => 1.0, "bob" => 0.8}
      }

      attrs = %{
        debate_id: debate_id,
        topic: "Deploy strategy",
        winner: %{from: "alice", content: "Blue-green"},
        consensus?: false,
        quorum_met?: false,
        policy: policy,
        weighted: weighted,
        vote_map: %{"alice" => "alice", "bob" => "bob"},
        session_id: nil,
        rounds: [%{proposals: [%{}], critiques: [], revisions: []}]
      }

      {:ok, node} = ConsensusTrail.log_outcome(attrs)

      assert node.metadata["final_outcome"] == "escalation"
      assert node.title =~ "Escalated"
    end
  end

  # --- Escalation Payload ---

  describe "build_escalation_payload/1" do
    test "returns a structured payload with all required fields" do
      debate_id = Ecto.UUID.generate()
      policy = ConsensusPolicy.default()

      weighted = %{
        winner: "alice",
        winning_weight_pct: 52.0,
        weighted_tallies: %{"alice" => 1.8, "bob" => 1.5},
        vote_weights: %{"alice" => 1.0, "bob" => 0.8}
      }

      attrs = %{
        debate_id: debate_id,
        topic: "Database choice",
        policy: policy,
        weighted: weighted,
        rounds: [
          %{proposals: [%{from: "alice"}, %{from: "bob"}], critiques: [], revisions: []},
          %{
            proposals: [%{from: "alice"}, %{from: "bob"}],
            critiques: [%{from: "bob"}],
            revisions: [%{from: "alice"}]
          }
        ]
      }

      payload = ConsensusTrail.build_escalation_payload(attrs)

      # Verify all required fields
      assert payload.debate_id == debate_id
      assert payload.topic == "Database choice"
      assert is_list(payload.competing_options)
      assert length(payload.competing_options) == 2
      assert is_map(payload.criteria_scores)
      assert is_list(payload.key_tradeoffs)
      assert is_list(payload.convergence_trend)
      assert length(payload.convergence_trend) == 2

      assert payload.suggested_next_action in [
               :revote,
               :narrow_scope,
               :defer_to_lead,
               :split_task
             ]

      assert is_binary(payload.policy_used)
      assert payload.rounds_completed == 2
    end

    test "competing_options are sorted by weighted score descending" do
      payload =
        build_payload_with_tallies(%{"alice" => 2.5, "bob" => 1.0, "carol" => 1.8})

      scores = Enum.map(payload.competing_options, & &1.weighted_score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "criteria_scores sum to approximately 100" do
      payload =
        build_payload_with_tallies(%{"alice" => 2.5, "bob" => 1.0})

      total = Enum.reduce(payload.criteria_scores, 0.0, fn {_k, v}, acc -> acc + v end)
      assert_in_delta total, 100.0, 0.5
    end

    test "key_tradeoffs contain pairwise comparisons" do
      payload =
        build_payload_with_tallies(%{"alice" => 2.5, "bob" => 1.0, "carol" => 1.8})

      assert length(payload.key_tradeoffs) >= 1

      Enum.each(payload.key_tradeoffs, fn tradeoff ->
        assert Map.has_key?(tradeoff, :option_a)
        assert Map.has_key?(tradeoff, :option_b)
        assert Map.has_key?(tradeoff, :tradeoff)
        assert is_binary(tradeoff.tradeoff)
      end)
    end

    test "suggested_next_action is a valid atom" do
      valid_actions = [:revote, :narrow_scope, :defer_to_lead, :split_task]

      payload =
        build_payload_with_tallies(%{"alice" => 2.5, "bob" => 1.0})

      assert payload.suggested_next_action in valid_actions
    end
  end

  # --- Collaboration Events ---

  describe "collaboration event emission" do
    test "emit_consensus_success broadcasts collab event", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "watcher")

      ConsensusTrail.emit_consensus_success(
        team_id,
        Ecto.UUID.generate(),
        %{from: "alice", content: "Use GenServer"},
        ConsensusPolicy.default(),
        %{rounds_completed: 2}
      )

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, payload}}
                      }},
                     500

      assert payload.type == :consensus_success
      assert payload.description =~ "Consensus reached"
      assert payload.metadata.debate_id
    end

    test "emit_consensus_deadlock broadcasts collab event", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "watcher")

      competing = [
        %{agent: "alice", content: "Option A", weighted_score: 2.5},
        %{agent: "bob", content: "Option B", weighted_score: 2.0}
      ]

      ConsensusTrail.emit_consensus_deadlock(
        team_id,
        Ecto.UUID.generate(),
        competing,
        %{rounds_completed: 3}
      )

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, payload}}
                      }},
                     500

      assert payload.type == :consensus_deadlock
      assert payload.description =~ "Deadlock"
      assert payload.description =~ "2 competing options"
    end

    test "emit_consensus_escalation broadcasts collab event", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "watcher")

      escalation = %{
        debate_id: Ecto.UUID.generate(),
        topic: "Deploy strategy",
        competing_options: [],
        criteria_scores: %{},
        key_tradeoffs: [],
        convergence_trend: [0.0, 50.0],
        suggested_next_action: :narrow_scope,
        policy_used: "quorum=majority",
        rounds_completed: 3
      }

      ConsensusTrail.emit_consensus_escalation(
        team_id,
        escalation.debate_id,
        escalation
      )

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, payload}}
                      }},
                     500

      assert payload.type == :consensus_escalation
      assert payload.description =~ "Escalated to user"
      assert payload.description =~ "narrow_scope"
      assert payload.metadata.escalation_payload == escalation
    end
  end

  # --- Integration: Full Debate Flow ---

  describe "full debate integration" do
    test "consensus path produces graph trail + success event", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "testing framework", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 500,
            policy: ConsensusPolicy.default()
          )
        end)

      # Wait for debate_start
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "testing framework", _}}
                      }},
                     1_000

      # Submit proposals
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     500

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Use ExUnit"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Use ExUnit"
      })

      # Let critique/revise phases timeout, then submit unanimous votes
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{
        from: "alice",
        choice: "alice",
        confidence: 0.9
      })

      Debate.submit_response(team_id, debate_id, :vote, %{
        from: "bob",
        choice: "alice",
        confidence: 0.8
      })

      {:ok, result} = Task.await(task, 15_000)

      # Verify consensus was reached
      assert result.consensus? == true

      # Verify round summary node exists
      outcome_nodes = Graph.list_nodes(node_type: :outcome)

      round_summaries =
        Enum.filter(outcome_nodes, fn n ->
          n.metadata["debate_id"] == debate_id and n.metadata["phase"] == "round_summary"
        end)

      assert length(round_summaries) >= 1

      # Verify final outcome node exists
      decision_nodes = Graph.list_nodes(node_type: :decision)

      outcome_nodes =
        Enum.filter(decision_nodes, fn n ->
          n.metadata["debate_id"] == debate_id and n.metadata["final_outcome"] != nil
        end)

      assert length(outcome_nodes) >= 1
      [outcome] = outcome_nodes
      assert outcome.metadata["final_outcome"] == "consensus"
      assert outcome.metadata["quorum_met"] == true

      # Verify consensus success event was emitted
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, %{type: :consensus_success}}}
                      }},
                     1_000
    end

    test "deadlock path produces graph trail + deadlock event", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      {:ok, policy} = ConsensusPolicy.new(quorum: :supermajority, on_deadlock: :escalate_to_user)

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "db choice", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 500,
            policy: policy
          )
        end)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "db choice", _}}
                      }},
                     1_000

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     500

      # Submit divergent proposals
      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "PostgreSQL"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "SQLite"
      })

      # Wait for vote phase, submit split votes (50/50 can't reach supermajority)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{from: "alice", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "bob", choice: "bob"})

      {:ok, result} = Task.await(task, 15_000)

      # Split votes can't reach supermajority => deadlock
      assert result.consensus? == false

      # Verify outcome node
      decision_nodes = Graph.list_nodes(node_type: :decision)

      outcome_nodes =
        Enum.filter(decision_nodes, fn n ->
          n.metadata["debate_id"] == debate_id and n.metadata["final_outcome"] != nil
        end)

      assert length(outcome_nodes) >= 1
      [outcome] = outcome_nodes
      assert outcome.metadata["final_outcome"] in ["deadlock", "escalation"]

      # Verify deadlock event was emitted
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, %{type: :consensus_deadlock}}}
                      }},
                     1_000

      # Verify escalation event was emitted (policy is escalate_to_user)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:collab_event, %{type: :consensus_escalation}}}
                      }},
                     1_000
    end
  end

  # --- Helpers ---

  defp build_payload_with_tallies(tallies) do
    {winner, _} = Enum.max_by(tallies, fn {_k, v} -> v end)
    total = Enum.reduce(tallies, 0.0, fn {_k, v}, acc -> acc + v end)
    winning_pct = if total > 0, do: tallies[winner] / total * 100, else: 0.0

    attrs = %{
      debate_id: Ecto.UUID.generate(),
      topic: "Test topic",
      policy: ConsensusPolicy.default(),
      weighted: %{
        winner: winner,
        winning_weight_pct: winning_pct,
        weighted_tallies: tallies,
        vote_weights: Map.new(tallies, fn {k, _v} -> {k, 1.0} end)
      },
      rounds: [
        %{proposals: [%{from: "alice"}, %{from: "bob"}], critiques: [], revisions: []},
        %{
          proposals: [%{from: "alice"}, %{from: "bob"}],
          critiques: [%{from: "bob"}],
          revisions: [%{from: "alice"}]
        }
      ]
    }

    ConsensusTrail.build_escalation_payload(attrs)
  end
end
