defmodule Loomkin.Teams.WeightedVotingTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Teams.Debate

  describe "expertise_weight/2" do
    test "coder gets high weight for code scope" do
      assert Debate.expertise_weight(:coder, "code") == 2.0
    end

    test "coder gets high weight for implementation scope" do
      assert Debate.expertise_weight(:coder, "implementation") == 2.0
    end

    test "researcher gets partial match weight for code scope (codebase contains code)" do
      assert Debate.expertise_weight(:researcher, "code") == 1.5
    end

    test "researcher gets high weight for research scope" do
      assert Debate.expertise_weight(:researcher, "research") == 2.0
    end

    test "lead gets high weight for architecture scope" do
      assert Debate.expertise_weight(:lead, "architecture") == 2.0
    end

    test "tester gets high weight for testing scope" do
      assert Debate.expertise_weight(:tester, "testing") == 2.0
    end

    test "reviewer gets high weight for review scope" do
      assert Debate.expertise_weight(:reviewer, "review") == 2.0
    end

    test "lead gets 2.0 for general scope (explicit strength)" do
      assert Debate.expertise_weight(:lead, "general") == 2.0
    end

    test "roles without general as strength get 1.0 for general scope" do
      for role <- [:coder, :researcher, :reviewer, :tester] do
        assert Debate.expertise_weight(role, "general") == 1.0,
               "#{role} should get 1.0 for general scope"
      end
    end

    test "unknown role returns 0.5 for specific scope" do
      assert Debate.expertise_weight(:unknown_role, "code") == 0.5
    end

    test "unknown role returns 1.0 for general scope" do
      assert Debate.expertise_weight(:unknown_role, "general") == 1.0
    end

    test "case insensitive scope matching" do
      assert Debate.expertise_weight(:coder, "CODE") == 2.0
    end

    test "partial match gives 1.5" do
      # "code_quality" contains "code" which is a strength of :reviewer
      assert Debate.expertise_weight(:reviewer, "code_quality") == 1.5
    end
  end

  describe "compute_vote_weight/4" do
    test "basic weight computation" do
      agent_info = %{capability_score: 0.8}
      weight = Debate.compute_vote_weight(agent_info, :coder, "code", 0.9)

      # expertise(2.0) * (0.5 + 0.25 * 0.8 + 0.25 * 0.9)
      # = 2.0 * (0.5 + 0.2 + 0.225) = 2.0 * 0.925 = 1.85
      assert_in_delta weight, 1.85, 0.001
    end

    test "defaults capability to 0.5 when missing" do
      agent_info = %{}
      weight = Debate.compute_vote_weight(agent_info, :coder, "general", 0.5)

      # expertise(1.0) * (0.5 + 0.25 * 0.5 + 0.25 * 0.5)
      # = 1.0 * (0.5 + 0.125 + 0.125) = 0.75
      assert_in_delta weight, 0.75, 0.001
    end

    test "clamps confidence to 0.0-1.0 range" do
      agent_info = %{capability_score: 0.5}

      # Confidence > 1.0 should be clamped to 1.0
      weight_high = Debate.compute_vote_weight(agent_info, :coder, "general", 2.0)
      weight_normal = Debate.compute_vote_weight(agent_info, :coder, "general", 1.0)
      assert_in_delta weight_high, weight_normal, 0.001

      # Confidence < 0.0 should be clamped to 0.0
      weight_low = Debate.compute_vote_weight(agent_info, :coder, "general", -1.0)
      weight_zero = Debate.compute_vote_weight(agent_info, :coder, "general", 0.0)
      assert_in_delta weight_low, weight_zero, 0.001
    end

    test "low expertise role gets lower weight" do
      agent_info = %{capability_score: 0.5}
      weight_expert = Debate.compute_vote_weight(agent_info, :coder, "code", 0.5)
      weight_non_expert = Debate.compute_vote_weight(agent_info, :researcher, "code", 0.5)

      assert weight_expert > weight_non_expert
    end
  end

  describe "tally_weighted_votes/4" do
    test "returns correct structure with empty votes" do
      result = Debate.tally_weighted_votes([], [], "topic", "general")

      assert result.winner == nil
      assert result.raw_tallies == %{}
      assert result.weighted_tallies == %{}
      assert result.vote_weights == %{}
      assert result.consensus? == false
      assert result.winning_weight_pct == 0.0
    end

    test "single vote is consensus" do
      votes = [%{from: "alice", choice: "option_a", confidence: 0.8}]
      agents = [%{name: "alice", role: :coder}]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert result.winner == "option_a"
      assert result.consensus? == true
      assert result.raw_tallies == %{"option_a" => 1}
      assert Map.has_key?(result.weighted_tallies, "option_a")
    end

    test "unanimous votes are consensus" do
      votes = [
        %{from: "alice", choice: "option_a", confidence: 0.8},
        %{from: "bob", choice: "option_a", confidence: 0.6}
      ]

      agents = [
        %{name: "alice", role: :coder},
        %{name: "bob", role: :researcher}
      ]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert result.winner == "option_a"
      assert result.consensus? == true
    end

    test "split votes are not consensus" do
      votes = [
        %{from: "alice", choice: "option_a", confidence: 0.8},
        %{from: "bob", choice: "option_b", confidence: 0.6}
      ]

      agents = [
        %{name: "alice", role: :coder},
        %{name: "bob", role: :researcher}
      ]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert result.consensus? == false
      assert result.winner in ["option_a", "option_b"]
    end

    test "expertise weighting can override raw vote count" do
      # 2 researchers vote for A, 1 coder votes for B
      # On a "code" scope, the coder's vote should be weighted higher
      votes = [
        %{from: "researcher1", choice: "option_a", confidence: 0.5},
        %{from: "researcher2", choice: "option_a", confidence: 0.5},
        %{from: "coder1", choice: "option_b", confidence: 0.9}
      ]

      agents = [
        %{name: "researcher1", role: :researcher, capability_score: 0.5},
        %{name: "researcher2", role: :researcher, capability_score: 0.5},
        %{name: "coder1", role: :coder, capability_score: 0.9}
      ]

      result = Debate.tally_weighted_votes(votes, agents, "code review", "code")

      # Raw: option_a wins 2-1
      assert result.raw_tallies["option_a"] == 2
      assert result.raw_tallies["option_b"] == 1

      # Weighted: coder's vote on code scope should be heavy
      # Researchers have expertise 0.5 on code scope
      # Coder has expertise 2.0 on code scope
      coder_weight = result.vote_weights["coder1"]
      researcher_weight = result.vote_weights["researcher1"]

      assert coder_weight > researcher_weight
    end

    test "vote weights are recorded per agent" do
      votes = [
        %{from: "alice", choice: "A", confidence: 0.7},
        %{from: "bob", choice: "B", confidence: 0.3}
      ]

      agents = [
        %{name: "alice", role: :lead},
        %{name: "bob", role: :tester}
      ]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert Map.has_key?(result.vote_weights, "alice")
      assert Map.has_key?(result.vote_weights, "bob")
      assert is_float(result.vote_weights["alice"])
      assert is_float(result.vote_weights["bob"])
    end

    test "missing confidence defaults to 0.5" do
      votes = [%{from: "alice", choice: "A"}]
      agents = [%{name: "alice", role: :coder}]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert result.winner == "A"
      assert Map.has_key?(result.vote_weights, "alice")
    end

    test "winning_weight_pct is calculated correctly" do
      votes = [
        %{from: "alice", choice: "A", confidence: 0.5},
        %{from: "bob", choice: "A", confidence: 0.5},
        %{from: "carol", choice: "B", confidence: 0.5}
      ]

      agents = [
        %{name: "alice", role: :coder},
        %{name: "bob", role: :coder},
        %{name: "carol", role: :coder}
      ]

      result = Debate.tally_weighted_votes(votes, agents, "topic", "general")

      assert result.winner == "A"
      # A has 2/3 of the weight when all agents have same role
      assert_in_delta result.winning_weight_pct, 66.67, 1.0
    end
  end
end
