defmodule Loomkin.Teams.ScopeDetectorTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.ScopeDetector

  describe "detect_tier/1 keyword classification" do
    test "fix/update/tweak keywords bias toward :quick" do
      for keyword <- ~w(fix update tweak rename) do
        {:ok, tier, _estimate} =
          ScopeDetector.detect_tier(%{task_description: "#{keyword} the typo in header"})

        assert tier == :quick, "expected :quick for keyword '#{keyword}', got #{inspect(tier)}"
      end
    end

    test "add/create/feature keywords bias toward :session" do
      for keyword <- ~w(add create endpoint feature) do
        {:ok, tier, _estimate} =
          ScopeDetector.detect_tier(%{task_description: "#{keyword} a new webhook handler"})

        assert tier == :session,
               "expected :session for keyword '#{keyword}', got #{inspect(tier)}"
      end
    end

    test "implement/refactor/epic keywords bias toward :campaign" do
      for keyword <- ~w(implement refactor epic migrate overhaul) do
        {:ok, tier, _estimate} =
          ScopeDetector.detect_tier(%{task_description: "#{keyword} the auth system"})

        assert tier == :campaign,
               "expected :campaign for keyword '#{keyword}', got #{inspect(tier)}"
      end
    end

    test "no matching keywords defaults to :session" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "do something with the code"})

      assert tier == :session
    end

    test "nil description defaults to :session" do
      {:ok, tier, _estimate} = ScopeDetector.detect_tier(%{})
      assert tier == :session
    end
  end

  describe "detect_tier/1 file count overrides" do
    test "high file count escalates quick keywords to :session" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix the bug", file_matches: 10})

      assert tier == :session
    end

    test "very high file count escalates to :campaign regardless of keywords" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix the typo", file_matches: 20})

      assert tier == :campaign
    end

    test "low file count does not downgrade keyword-based tier" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "refactor auth module", file_matches: 1})

      assert tier == :campaign
    end
  end

  describe "detect_tier/1 plan_doc" do
    test "plan_doc always triggers :campaign" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix the typo", plan_doc: true})

      assert tier == :campaign
    end

    test "plan_doc false does not force campaign" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix the typo", plan_doc: false})

      assert tier == :quick
    end
  end

  describe "detect_tier/1 explicit scope override" do
    test "explicit_scope overrides all other signals" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{
          task_description: "refactor the entire system",
          file_matches: 50,
          explicit_scope: :quick
        })

      assert tier == :quick
    end

    test "explicit_scope :campaign overrides quick signals" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix typo", explicit_scope: :campaign})

      assert tier == :campaign
    end
  end

  describe "detect_tier/1 campaign phrases" do
    test "take your time forces :campaign" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix this bug, take your time"})

      assert tier == :campaign
    end

    test "heading to bed forces :campaign" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "work on the tests, heading to bed"})

      assert tier == :campaign
    end

    test "be thorough forces :campaign" do
      {:ok, tier, _estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix the linter issues, be thorough"})

      assert tier == :campaign
    end
  end

  describe "detect_tier/1 estimate" do
    test "estimate includes file count from file_matches" do
      {:ok, _tier, estimate} =
        ScopeDetector.detect_tier(%{task_description: "fix a bug", file_matches: 2})

      assert estimate.files == 2
      assert is_float(estimate.estimated_cost)
    end

    test "estimate uses envelope max when no file_matches" do
      {:ok, :quick, estimate} = ScopeDetector.detect_tier(%{task_description: "fix a typo"})
      assert estimate.files == 3
    end
  end

  describe "tier_envelope/1" do
    test "quick envelope" do
      assert ScopeDetector.tier_envelope(:quick) == %{max_files: 3, max_cost: 0.50}
    end

    test "session envelope" do
      assert ScopeDetector.tier_envelope(:session) == %{max_files: 15, max_cost: 5.00}
    end

    test "campaign envelope" do
      assert ScopeDetector.tier_envelope(:campaign) == %{max_files: 50, max_cost: 50.00}
    end
  end

  describe "exceeded?/2" do
    test "within bounds returns :ok" do
      assert ScopeDetector.exceeded?(:quick, %{files: 2, cost: 0.30}) == :ok
    end

    test "at exact limit returns :ok" do
      assert ScopeDetector.exceeded?(:quick, %{files: 3, cost: 0.50}) == :ok
    end

    test "files exceeded returns {:exceeded, :files, details}" do
      assert {:exceeded, :files, details} =
               ScopeDetector.exceeded?(:quick, %{files: 5, cost: 0.10})

      assert details.current == 5
      assert details.limit == 3
      assert details.overage == 2
    end

    test "cost exceeded returns {:exceeded, :cost, details}" do
      assert {:exceeded, :cost, details} =
               ScopeDetector.exceeded?(:quick, %{files: 1, cost: 1.00})

      assert details.current == 1.00
      assert details.limit == 0.50
      assert details.overage == 0.50
    end

    test "both exceeded reports files first" do
      assert {:exceeded, :files, _details} =
               ScopeDetector.exceeded?(:quick, %{files: 10, cost: 10.00})
    end

    test "session tier exceeded checks" do
      assert :ok = ScopeDetector.exceeded?(:session, %{files: 15, cost: 5.00})

      assert {:exceeded, :files, _} =
               ScopeDetector.exceeded?(:session, %{files: 16, cost: 1.00})
    end

    test "campaign tier exceeded checks" do
      assert :ok = ScopeDetector.exceeded?(:campaign, %{files: 50, cost: 50.00})

      assert {:exceeded, :cost, _} =
               ScopeDetector.exceeded?(:campaign, %{files: 1, cost: 51.00})
    end
  end
end
