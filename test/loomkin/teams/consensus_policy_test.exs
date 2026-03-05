defmodule Loomkin.Teams.ConsensusPolicyTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.ConsensusPolicy

  describe "default/0" do
    test "returns a policy with expected defaults" do
      policy = ConsensusPolicy.default()
      assert %ConsensusPolicy{} = policy
      assert policy.quorum == :majority
      assert policy.max_rounds == 3
      assert policy.scope == "general"
      assert policy.on_deadlock == :escalate_to_user
    end
  end

  describe "new/1" do
    test "builds a valid policy from keyword list" do
      assert {:ok, policy} = ConsensusPolicy.new(quorum: :unanimous, max_rounds: 5)
      assert policy.quorum == :unanimous
      assert policy.max_rounds == 5
      assert policy.scope == "general"
      assert policy.on_deadlock == :escalate_to_user
    end

    test "builds a valid policy from a map" do
      assert {:ok, policy} = ConsensusPolicy.new(%{quorum: :supermajority, scope: "code"})
      assert policy.quorum == :supermajority
      assert policy.scope == "code"
    end

    test "accepts numeric quorum threshold" do
      assert {:ok, policy} = ConsensusPolicy.new(quorum: 4)
      assert policy.quorum == 4
    end

    test "accepts all valid deadlock strategies" do
      for strategy <- [:escalate_to_user, :leader_decides, :random_tiebreak] do
        assert {:ok, policy} = ConsensusPolicy.new(on_deadlock: strategy)
        assert policy.on_deadlock == strategy
      end
    end

    test "accepts all valid quorum modes" do
      for mode <- [:unanimous, :majority, :supermajority] do
        assert {:ok, policy} = ConsensusPolicy.new(quorum: mode)
        assert policy.quorum == mode
      end
    end

    test "uses defaults when no attrs given" do
      assert {:ok, policy} = ConsensusPolicy.new()
      assert policy == ConsensusPolicy.default()
    end

    test "rejects invalid quorum" do
      assert {:error, [msg]} = ConsensusPolicy.new(quorum: :invalid)
      assert msg =~ "invalid quorum"
      assert msg =~ ":invalid"
    end

    test "rejects zero quorum" do
      assert {:error, [msg]} = ConsensusPolicy.new(quorum: 0)
      assert msg =~ "invalid quorum"
    end

    test "rejects negative quorum" do
      assert {:error, [msg]} = ConsensusPolicy.new(quorum: -1)
      assert msg =~ "invalid quorum"
    end

    test "rejects non-positive max_rounds" do
      assert {:error, [msg]} = ConsensusPolicy.new(max_rounds: 0)
      assert msg =~ "invalid max_rounds"
    end

    test "rejects string max_rounds" do
      assert {:error, [msg]} = ConsensusPolicy.new(max_rounds: "three")
      assert msg =~ "invalid max_rounds"
    end

    test "rejects empty scope" do
      assert {:error, [msg]} = ConsensusPolicy.new(scope: "")
      assert msg =~ "invalid scope"
    end

    test "rejects non-string scope" do
      assert {:error, [msg]} = ConsensusPolicy.new(scope: 42)
      assert msg =~ "invalid scope"
    end

    test "rejects invalid deadlock strategy" do
      assert {:error, [msg]} = ConsensusPolicy.new(on_deadlock: :panic)
      assert msg =~ "invalid on_deadlock"
      assert msg =~ ":panic"
    end

    test "returns multiple errors for multiple invalid fields" do
      assert {:error, errors} =
               ConsensusPolicy.new(quorum: :bad, max_rounds: -1, on_deadlock: :nope)

      assert length(errors) == 3
    end
  end

  describe "from_config/1" do
    test "parses valid config with atom keys" do
      config = %{quorum: "majority", max_rounds: 5, scope: "code", on_deadlock: "leader_decides"}
      assert {:ok, policy} = ConsensusPolicy.from_config(config)
      assert policy.quorum == :majority
      assert policy.max_rounds == 5
      assert policy.scope == "code"
      assert policy.on_deadlock == :leader_decides
    end

    test "parses valid config with string keys" do
      config = %{
        "quorum" => "supermajority",
        "max_rounds" => 2,
        "on_deadlock" => "random_tiebreak"
      }

      assert {:ok, policy} = ConsensusPolicy.from_config(config)
      assert policy.quorum == :supermajority
      assert policy.max_rounds == 2
      assert policy.on_deadlock == :random_tiebreak
    end

    test "parses numeric quorum from string" do
      config = %{"quorum" => "3"}
      assert {:ok, policy} = ConsensusPolicy.from_config(config)
      assert policy.quorum == 3
    end

    test "uses defaults for missing keys" do
      assert {:ok, policy} = ConsensusPolicy.from_config(%{})
      assert policy == ConsensusPolicy.default()
    end

    test "returns error for invalid values" do
      config = %{quorum: "invalid_quorum_mode"}
      assert {:error, [msg]} = ConsensusPolicy.from_config(config)
      assert msg =~ "invalid quorum"
    end
  end

  describe "quorum_met?/4" do
    test "unanimous requires all eligible voters AND 100% agreement" do
      assert ConsensusPolicy.quorum_met?(:unanimous, 100.0, 3, 3) == true
      assert ConsensusPolicy.quorum_met?(:unanimous, 100.0, 2, 3) == false
      assert ConsensusPolicy.quorum_met?(:unanimous, 100.0, 0, 0) == false
      # Split vote: full participation but not unanimous agreement
      assert ConsensusPolicy.quorum_met?(:unanimous, 50.0, 2, 2) == false
      assert ConsensusPolicy.quorum_met?(:unanimous, 66.7, 3, 3) == false
    end

    test "majority requires > 50% weighted" do
      assert ConsensusPolicy.quorum_met?(:majority, 51.0, 3, 5) == true
      assert ConsensusPolicy.quorum_met?(:majority, 50.0, 3, 5) == false
      assert ConsensusPolicy.quorum_met?(:majority, 66.7, 2, 3) == true
    end

    test "supermajority requires >= 66.67% weighted" do
      assert ConsensusPolicy.quorum_met?(:supermajority, 66.67, 3, 5) == true
      assert ConsensusPolicy.quorum_met?(:supermajority, 66.66, 3, 5) == false
      assert ConsensusPolicy.quorum_met?(:supermajority, 80.0, 4, 5) == true
    end

    test "numeric threshold requires at least N voters" do
      assert ConsensusPolicy.quorum_met?(3, 40.0, 3, 5) == true
      assert ConsensusPolicy.quorum_met?(3, 40.0, 2, 5) == false
      assert ConsensusPolicy.quorum_met?(1, 100.0, 1, 1) == true
    end

    test "zero voters never meets quorum" do
      assert ConsensusPolicy.quorum_met?(:majority, 0.0, 0, 5) == false
      assert ConsensusPolicy.quorum_met?(:unanimous, 0.0, 0, 0) == false
    end
  end

  describe "validate/1" do
    test "valid policy returns empty list" do
      assert ConsensusPolicy.validate(ConsensusPolicy.default()) == []
    end

    test "invalid policy returns error list" do
      policy = %ConsensusPolicy{quorum: :bad, max_rounds: -1, scope: "", on_deadlock: :nope}
      errors = ConsensusPolicy.validate(policy)
      assert length(errors) == 4
    end
  end
end
