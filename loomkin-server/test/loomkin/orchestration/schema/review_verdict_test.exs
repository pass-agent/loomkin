defmodule Loomkin.Orchestration.Schema.ReviewVerdictTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Schema.ReviewVerdict

  describe "validate_evidence/1" do
    test "rejects empty evidence" do
      assert {:error, _} = ReviewVerdict.validate_evidence([])
    end

    test "rejects evidence missing file:line shape" do
      assert {:error, _} = ReviewVerdict.validate_evidence(["just a string"])
      assert {:error, _} = ReviewVerdict.validate_evidence(["foo.ex"])
      assert {:error, _} = ReviewVerdict.validate_evidence([":42"])
    end

    test "accepts file:line evidence" do
      assert :ok = ReviewVerdict.validate_evidence(["lib/foo.ex:12"])
      assert :ok = ReviewVerdict.validate_evidence(["a/b/c.ex:99", "x.exs:1"])
    end
  end

  describe "changeset/2" do
    test "fail verdict requires at least one blocking issue" do
      cs =
        ReviewVerdict.changeset(%ReviewVerdict{}, %{
          verdict: :fail,
          reviewer: "TestReviewer",
          evidence: ["lib/x.ex:1"],
          blocking: []
        })

      refute cs.valid?
      assert {:blocking, _} = Enum.find(cs.errors, fn {k, _} -> k == :blocking end)
    end

    test "pass verdict accepts empty blocking" do
      cs =
        ReviewVerdict.changeset(%ReviewVerdict{}, %{
          verdict: :pass,
          reviewer: "TestReviewer",
          evidence: ["lib/x.ex:1"],
          blocking: []
        })

      assert cs.valid?
    end
  end
end
