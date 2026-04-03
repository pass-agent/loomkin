defmodule Loomkin.Teams.DebateProtocolTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Debate, Manager, ConsensusPolicy}

  setup do
    {:ok, team_id} = Manager.create_team(name: "debate-protocol-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  # -- Structured Proposal Normalization --

  describe "normalize_proposal/1" do
    test "passes through structured proposals with approach field" do
      proposal = %{
        from: "alice",
        approach: "Use microservices",
        scores: %{"scalability" => 8},
        tradeoffs: ["complexity"],
        confidence: 80
      }

      result = Debate.normalize_proposal(proposal)

      assert result.approach == "Use microservices"
      assert result.scores == %{"scalability" => 8}
      assert result.tradeoffs == ["complexity"]
      assert result.confidence == 80
      # Should add content from approach
      assert result.content == "Use microservices"
    end

    test "fills defaults for structured proposals missing optional fields" do
      proposal = %{from: "alice", approach: "Use monolith"}

      result = Debate.normalize_proposal(proposal)

      assert result.approach == "Use monolith"
      assert result.scores == %{}
      assert result.tradeoffs == []
      assert result.confidence == 50
      assert result.content == "Use monolith"
    end

    test "preserves plain-text proposals with content" do
      proposal = %{from: "bob", content: "Just use Phoenix"}

      result = Debate.normalize_proposal(proposal)

      assert result.content == "Just use Phoenix"
      assert result.confidence == 50
      refute Map.has_key?(result, :approach)
    end

    test "parses JSON structured content from plain text" do
      json =
        Jason.encode!(%{
          "approach" => "Event sourcing",
          "scores" => %{"resilience" => 9},
          "tradeoffs" => ["learning curve"],
          "confidence" => 75
        })

      proposal = %{from: "carol", content: json}

      result = Debate.normalize_proposal(proposal)

      assert result.approach == "Event sourcing"
      assert result.scores == %{"resilience" => 9}
      assert result.tradeoffs == ["learning curve"]
      assert result.confidence == 75
      assert result.content == "Event sourcing"
    end

    test "falls back gracefully for invalid JSON" do
      proposal = %{from: "dave", content: "{not valid json at all"}

      result = Debate.normalize_proposal(proposal)

      assert result.content == "{not valid json at all"
      assert result.confidence == 50
      refute Map.has_key?(result, :approach)
    end

    test "falls back for JSON without approach key" do
      json = Jason.encode!(%{"other_key" => "value"})
      proposal = %{from: "eve", content: json}

      result = Debate.normalize_proposal(proposal)

      assert result.content == json
      assert result.confidence == 50
    end

    test "handles proposals with only from (no content)" do
      proposal = %{from: "frank"}

      result = Debate.normalize_proposal(proposal)

      assert result.content == "frank's proposal"
      assert result.confidence == 50
    end
  end

  # -- Convergence Tracking --

  describe "compute_round_convergence/5" do
    test "detects full agreement when all proposals match", %{team_id: team_id} do
      round_data = %{
        proposals: [
          %{from: "alice", content: "Use Elixir", confidence: 80},
          %{from: "bob", content: "Use Elixir", confidence: 70}
        ],
        revisions: []
      }

      convergence =
        Debate.compute_round_convergence(team_id, round_data, [], ["alice", "bob"], "general")

      assert convergence.agreement_pct == 100.0
      assert convergence.unique_positions == 1
      assert convergence.quorum_met == true
    end

    test "detects split when proposals differ", %{team_id: team_id} do
      round_data = %{
        proposals: [
          %{from: "alice", content: "Use Elixir", confidence: 80},
          %{from: "bob", content: "Use Rust", confidence: 70}
        ],
        revisions: []
      }

      convergence =
        Debate.compute_round_convergence(team_id, round_data, [], ["alice", "bob"], "general")

      assert convergence.agreement_pct == 50.0
      assert convergence.unique_positions == 2
      assert convergence.quorum_met == false
    end

    test "uses revisions over proposals when available", %{team_id: team_id} do
      round_data = %{
        proposals: [
          %{from: "alice", content: "Use Elixir", confidence: 80},
          %{from: "bob", content: "Use Rust", confidence: 70}
        ],
        revisions: [
          %{from: "alice", content: "Use Elixir", confidence: 85},
          %{from: "bob", content: "Use Elixir", confidence: 75}
        ]
      }

      convergence =
        Debate.compute_round_convergence(team_id, round_data, [], ["alice", "bob"], "general")

      # Revisions show full agreement
      assert convergence.agreement_pct == 100.0
      assert convergence.quorum_met == true
    end

    test "computes delta from prior round", %{team_id: team_id} do
      prior_convergence = %{
        weighted_top_pct: 60.0,
        agreement_pct: 50.0,
        unique_positions: 2,
        quorum_met: false,
        stalled: false
      }

      prior_round = %{
        round: 1,
        proposals: [%{from: "alice", content: "A"}, %{from: "bob", content: "B"}],
        critiques: [],
        revisions: [],
        convergence: prior_convergence
      }

      round_data = %{
        proposals: [
          %{from: "alice", content: "A", confidence: 80},
          %{from: "bob", content: "A", confidence: 70}
        ],
        revisions: []
      }

      convergence =
        Debate.compute_round_convergence(
          team_id,
          round_data,
          [prior_round],
          ["alice", "bob"],
          "general"
        )

      # Delta should be positive since we went from split to agreement
      assert convergence.delta > 0
    end

    test "marks stalled when delta is within epsilon", %{team_id: team_id} do
      # First, compute an actual round 1 convergence to get realistic numbers
      round1_data = %{
        proposals: [
          %{from: "alice", content: "A", confidence: 50},
          %{from: "bob", content: "B", confidence: 50}
        ],
        revisions: []
      }

      round1_convergence =
        Debate.compute_round_convergence(
          team_id,
          round1_data,
          [],
          ["alice", "bob"],
          "general"
        )

      prior_round = %{
        round: 1,
        proposals: round1_data.proposals,
        critiques: [],
        revisions: [],
        convergence: round1_convergence
      }

      # Round 2: same positions, same split
      round2_data = %{
        proposals: [
          %{from: "alice", content: "A", confidence: 50},
          %{from: "bob", content: "B", confidence: 50}
        ],
        revisions: []
      }

      convergence =
        Debate.compute_round_convergence(
          team_id,
          round2_data,
          [prior_round],
          ["alice", "bob"],
          "general"
        )

      # Same positions = tiny delta = stalled
      assert convergence.stalled == true
      assert abs(convergence.delta) < 2.0
    end
  end

  # -- Outcome States --

  describe "outcome states" do
    test "returns outcome and rationale in debate result", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "test outcomes", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 100
          )
        end)

      # Let all phases timeout
      {:ok, result} = Task.await(task, 10_000)

      assert is_atom(result.outcome)
      assert result.outcome in [:consensus_reached, :deadlock, :escalated, :rounds_exhausted]
      assert is_binary(result.rationale)
    end

    test "consensus result when votes are unanimous", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "consensus test", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 300
          )
        end)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "consensus test", _}}
                      }},
                     500

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     500

      # Both propose the same thing
      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Use Elixir"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Use Elixir"
      })

      # Skip critique/revise, then vote unanimously
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _proposals}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{from: "alice", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "bob", choice: "alice"})

      {:ok, result} = Task.await(task, 10_000)

      assert result.consensus? == true
      assert result.outcome == :consensus_reached
      assert String.contains?(result.rationale, "Consensus reached")
    end

    test "escalated outcome with escalate_to_user policy when quorum not met", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")
      Loomkin.Teams.Comms.subscribe(team_id, "carol")

      # Supermajority requires >= 66.67% — a 2:1 split with 3 agents
      # where the split is even (alice vs bob vs carol all different) won't meet it
      {:ok, policy} = ConsensusPolicy.new(quorum: :supermajority, on_deadlock: :escalate_to_user)

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "escalation test", ["alice", "bob", "carol"],
            max_rounds: 1,
            round_timeout_ms: 500,
            policy: policy
          )
        end)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "escalation test", _opts}}
                      }},
                     1_000

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     1_000

      # All three propose different things
      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Approach A"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Approach B"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "carol",
        content: "Approach C"
      })

      # Vote: each votes for themselves (3-way split, no supermajority)
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _proposals}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{from: "alice", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "bob", choice: "bob"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "carol", choice: "carol"})

      {:ok, result} = Task.await(task, 10_000)

      assert result.consensus? == false
      assert result.outcome == :escalated
      assert String.contains?(result.rationale, "escalating to user")
    end
  end

  # -- Backward Compatibility --

  describe "backward compatibility" do
    test "works without explicit policy", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "compat test", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 100
          )
        end)

      {:ok, result} = Task.await(task, 10_000)

      # Should have default policy
      assert result.policy == ConsensusPolicy.default()
      # Should have all new fields
      assert Map.has_key?(result, :outcome)
      assert Map.has_key?(result, :rationale)
      # Should still have old fields
      assert Map.has_key?(result, :winner)
      assert Map.has_key?(result, :votes)
      assert Map.has_key?(result, :rounds)
      assert Map.has_key?(result, :consensus?)
      assert Map.has_key?(result, :weighted_tallies)
      assert Map.has_key?(result, :vote_weights)
    end

    test "rounds contain convergence data", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "convergence data test", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 100
          )
        end)

      {:ok, result} = Task.await(task, 10_000)

      assert length(result.rounds) == 1
      round = hd(result.rounds)
      assert Map.has_key?(round, :convergence)
      convergence = round.convergence

      assert Map.has_key?(convergence, :agreement_pct)
      assert Map.has_key?(convergence, :weighted_top_pct)
      assert Map.has_key?(convergence, :delta)
      assert Map.has_key?(convergence, :quorum_met)
    end
  end

  # -- Early-stop --

  describe "early-stop" do
    test "can stop early when quorum reached", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "early stop test", ["alice", "bob"],
            max_rounds: 5,
            round_timeout_ms: 300
          )
        end)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "early stop test", _}}
                      }},
                     500

      # Round 1: both propose the same thing
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     500

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Shared approach"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Shared approach"
      })

      # Let critique/revise timeout, then handle vote
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _proposals}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{from: "alice", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "bob", choice: "alice"})

      {:ok, result} = Task.await(task, 15_000)

      # Should have stopped early — fewer than 5 rounds
      assert length(result.rounds) <= 2
      assert result.consensus? == true
    end
  end

  # -- Policy integration --

  describe "policy integration" do
    test "uses policy scope for weighted voting", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      {:ok, policy} = ConsensusPolicy.new(scope: "code", quorum: :majority)

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "policy scope test", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 100,
            policy: policy
          )
        end)

      {:ok, result} = Task.await(task, 10_000)

      assert result.policy.scope == "code"
    end

    test "uses policy max_rounds", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      {:ok, policy} = ConsensusPolicy.new(max_rounds: 2)

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "max rounds test", ["alice", "bob"],
            round_timeout_ms: 50,
            policy: policy
          )
        end)

      {:ok, result} = Task.await(task, 10_000)

      # Should respect policy max_rounds
      assert length(result.rounds) <= 2
    end
  end
end
