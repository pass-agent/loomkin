defmodule Loomkin.Orchestration.GateRunnerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.GateRunner
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  setup do
    # Application-level Task.Supervisor exists once the app boots, but unit
    # tests should not depend on application start order — spin up an isolated
    # supervisor for this test.
    sup = String.to_atom("GateRunnerTest.Sup.#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: sup})
    %{sup: sup}
  end

  defmodule AlwaysPass do
    @behaviour Loomkin.Orchestration.Reviewer
    def name, do: :always_pass
    def rubric, do: ""

    def review(_payload) do
      {:ok,
       %ReviewVerdict{
         verdict: :pass,
         reviewer: inspect(__MODULE__),
         evidence: ["lib/foo.ex:1"],
         blocking: [],
         warnings: [],
         rationale: "ok"
       }}
    end
  end

  defmodule AlwaysFail do
    @behaviour Loomkin.Orchestration.Reviewer
    def name, do: :always_fail
    def rubric, do: ""

    def review(_payload) do
      {:ok,
       %ReviewVerdict{
         verdict: :fail,
         reviewer: inspect(__MODULE__),
         evidence: ["lib/foo.ex:2"],
         blocking: ["nope"],
         warnings: [],
         rationale: "no"
       }}
    end
  end

  defmodule Crashes do
    @behaviour Loomkin.Orchestration.Reviewer
    def name, do: :crashes
    def rubric, do: ""

    def review(_), do: raise("boom")
  end

  test "all-pass aggregates to :pass", %{sup: sup} do
    {agg, verdicts} =
      GateRunner.run([AlwaysPass, AlwaysPass], %{epic_id: "abc"}, task_supervisor: sup)

    assert agg == :pass
    assert length(verdicts) == 2
    assert Enum.all?(verdicts, &(&1.verdict == :pass))
  end

  test "one fail aggregates to :fail", %{sup: sup} do
    {agg, verdicts} =
      GateRunner.run([AlwaysPass, AlwaysFail], %{epic_id: "abc"}, task_supervisor: sup)

    assert agg == :fail
    assert Enum.any?(verdicts, &(&1.verdict == :fail))
  end

  test "crashing reviewer is converted to a fail verdict", %{sup: sup} do
    {agg, verdicts} =
      GateRunner.run([AlwaysPass, Crashes], %{epic_id: "abc"}, task_supervisor: sup)

    assert agg == :fail
    assert Enum.any?(verdicts, &(&1.verdict == :fail and &1.blocking != []))
  end

  test "fans reviewers out in parallel", %{sup: sup} do
    defmodule SlowOk do
      @behaviour Loomkin.Orchestration.Reviewer
      def name, do: :slow_ok
      def rubric, do: ""

      def review(_payload) do
        Process.sleep(80)

        {:ok,
         %Loomkin.Orchestration.Schema.ReviewVerdict{
           verdict: :pass,
           reviewer: inspect(__MODULE__),
           evidence: ["lib/foo.ex:1"],
           blocking: [],
           warnings: [],
           rationale: "ok"
         }}
      end
    end

    reviewers = List.duplicate(SlowOk, 5)

    {time_us, {agg, verdicts}} =
      :timer.tc(fn -> GateRunner.run(reviewers, %{epic_id: "x"}, task_supervisor: sup) end)

    assert agg == :pass
    assert length(verdicts) == 5
    # Sequential would be 5×80 = 400ms. Parallel should finish well under 300ms.
    assert div(time_us, 1000) < 300
  end
end
