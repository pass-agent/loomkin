defmodule Loomkin.Orchestration.Gates.PlanReviewGateTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Gates.PlanReviewGate
  alias Loomkin.Orchestration.LLM.Stub

  setup do
    sup = String.to_atom("PlanReviewSup.#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: sup})
    start_supervised!(Stub)

    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)

    %{sup: sup}
  end

  defp ok_response(reviewer) do
    {:by_reviewer, reviewer,
     ~s({"verdict":"pass","evidence":["plan:1"],"blocking":[],"warnings":[],"rationale":"ok"})}
  end

  defp fail_response(reviewer) do
    {:by_reviewer, reviewer,
     ~s({"verdict":"fail","evidence":["plan:2"],"blocking":["nope"],"warnings":[],"rationale":"no"})}
  end

  test "all three reviewers pass → :pass aggregate", %{sup: sup} do
    Stub.queue([
      ok_response(:feasibility),
      ok_response(:completeness),
      ok_response(:scope_alignment)
    ])

    {agg, verdicts} =
      PlanReviewGate.run(%{epic_id: "e1", artifact: "plan body"}, task_supervisor: sup)

    assert agg == :pass
    assert length(verdicts) == 3
  end

  test "one fail → :fail aggregate", %{sup: sup} do
    Stub.queue([
      ok_response(:feasibility),
      fail_response(:completeness),
      ok_response(:scope_alignment)
    ])

    {agg, verdicts} =
      PlanReviewGate.run(%{epic_id: "e1", artifact: "plan body"}, task_supervisor: sup)

    assert agg == :fail
    assert Enum.any?(verdicts, &(&1.verdict == :fail))
  end
end
