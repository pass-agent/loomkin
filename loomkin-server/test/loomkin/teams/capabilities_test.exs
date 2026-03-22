defmodule Loomkin.Teams.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Capabilities, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "cap-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "record_completion/4 and get_capabilities/2" do
    test "records successes and failures", %{team_id: team_id} do
      assert :ok = Capabilities.record_completion(team_id, "alice", :coding, :success)
      assert :ok = Capabilities.record_completion(team_id, "alice", :coding, :success)
      assert :ok = Capabilities.record_completion(team_id, "alice", :coding, :failure)

      caps = Capabilities.get_capabilities(team_id, "alice")
      assert length(caps) == 1

      coding = hd(caps)
      assert coding.task_type == :coding
      assert coding.successes == 2
      assert coding.failures == 1
    end

    test "tracks multiple task types per agent", %{team_id: team_id} do
      Capabilities.record_completion(team_id, "bob", :coding, :success)
      Capabilities.record_completion(team_id, "bob", :research, :success)
      Capabilities.record_completion(team_id, "bob", :testing, :failure)

      caps = Capabilities.get_capabilities(team_id, "bob")
      assert length(caps) == 3

      types = Enum.map(caps, & &1.task_type) |> Enum.sort()
      assert types == [:coding, :research, :testing]
    end

    test "returns empty list for unknown agent", %{team_id: team_id} do
      assert Capabilities.get_capabilities(team_id, "nobody") == []
    end
  end

  describe "best_agent_for/2" do
    test "ranks agents by capability score", %{team_id: team_id} do
      # Alice: 3 successes, 0 failures at coding
      for _ <- 1..3, do: Capabilities.record_completion(team_id, "alice", :coding, :success)

      # Bob: 1 success, 2 failures at coding
      Capabilities.record_completion(team_id, "bob", :coding, :success)
      Capabilities.record_completion(team_id, "bob", :coding, :failure)
      Capabilities.record_completion(team_id, "bob", :coding, :failure)

      ranked = Capabilities.best_agent_for(team_id, :coding)
      assert length(ranked) == 2
      assert hd(ranked).agent == "alice"
    end

    test "returns empty list when no data", %{team_id: team_id} do
      assert Capabilities.best_agent_for(team_id, :research) == []
    end

    test "handles string task type", %{team_id: team_id} do
      Capabilities.record_completion(team_id, "alice", :coding, :success)
      ranked = Capabilities.best_agent_for(team_id, :coding)
      assert length(ranked) == 1
    end
  end

  describe "infer_task_type/1" do
    test "infers coding from implementation keywords" do
      assert Capabilities.infer_task_type("Implement user authentication") == :coding
    end

    test "infers research from investigation keywords" do
      assert Capabilities.infer_task_type("Research the codebase patterns") == :research
    end

    test "infers testing from test keywords" do
      assert Capabilities.infer_task_type("Write unit tests for auth module") == :testing
    end

    test "infers review from review keywords" do
      assert Capabilities.infer_task_type("Review the pull request changes") == :review
    end

    test "defaults to coding for nil" do
      assert Capabilities.infer_task_type(nil) == :coding
    end

    test "defaults to coding for empty string" do
      assert Capabilities.infer_task_type("") == :coding
    end

    test "defaults to coding for unrecognized text" do
      assert Capabilities.infer_task_type("xyzzy foobar") == :coding
    end
  end

  describe "score calculation" do
    test "agent with higher success rate ranks higher", %{team_id: team_id} do
      # Alice: 5/5 = 100% success, score = 1.0 * log2(6) ≈ 2.58
      for _ <- 1..5, do: Capabilities.record_completion(team_id, "alice", :coding, :success)

      # Bob: 5/10 = 50% success, score = 0.5 * log2(11) ≈ 1.73
      for _ <- 1..5, do: Capabilities.record_completion(team_id, "bob", :coding, :success)
      for _ <- 1..5, do: Capabilities.record_completion(team_id, "bob", :coding, :failure)

      [first | _] = Capabilities.best_agent_for(team_id, :coding)
      assert first.agent == "alice"
    end

    test "more experience with same rate ranks higher", %{team_id: team_id} do
      # Alice: 10/10, score = 1.0 * log2(11) ≈ 3.46
      for _ <- 1..10, do: Capabilities.record_completion(team_id, "alice", :coding, :success)

      # Bob: 1/1, score = 1.0 * log2(2) = 1.0
      Capabilities.record_completion(team_id, "bob", :coding, :success)

      [first | _] = Capabilities.best_agent_for(team_id, :coding)
      assert first.agent == "alice"
    end
  end
end
