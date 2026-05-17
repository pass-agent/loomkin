defmodule Loomkin.Orchestration.Gates.AdversarialReviewGateTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Gates.AdversarialReviewGate
  alias Loomkin.Orchestration.LLM.Stub

  setup do
    sup = String.to_atom("AdvReviewSup.#{System.unique_integer([:positive])}")
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

  test "PASS verdict with file:line evidence stays PASS", %{sup: sup} do
    Stub.queue([
      {:by_reviewer, :dod_verifier,
       ~s({"verdict":"pass","evidence":["lib/x.ex:42","test/x_test.exs:10"],"blocking":[],"warnings":[],"rationale":"ok"})}
    ])

    {agg, [verdict]} =
      AdversarialReviewGate.run(%{epic_id: "e1", artifact: "diff..."}, task_supervisor: sup)

    assert agg == :pass
    assert verdict.verdict == :pass
  end

  test "PASS verdict with NO file:line evidence is rewritten to FAIL", %{sup: sup} do
    Stub.queue([
      {:by_reviewer, :dod_verifier,
       ~s({"verdict":"pass","evidence":[],"blocking":[],"warnings":[],"rationale":"ok"})}
    ])

    {agg, [verdict]} =
      AdversarialReviewGate.run(%{epic_id: "e1", artifact: "diff..."}, task_supervisor: sup)

    assert agg == :fail
    assert verdict.verdict == :fail

    assert Enum.any?(verdict.blocking, &String.contains?(&1, "adversarial-review-gate rejected"))
  end

  test "PASS verdict with malformed evidence (no line number) is rewritten to FAIL", %{sup: sup} do
    Stub.queue([
      {:by_reviewer, :dod_verifier,
       ~s({"verdict":"pass","evidence":["just_a_string","lib/foo.ex"],"blocking":[],"warnings":[],"rationale":"ok"})}
    ])

    {agg, [verdict]} =
      AdversarialReviewGate.run(%{epic_id: "e1", artifact: "diff..."}, task_supervisor: sup)

    assert agg == :fail
    assert verdict.verdict == :fail
  end

  test "FAIL verdict is preserved unchanged", %{sup: sup} do
    Stub.queue([
      {:by_reviewer, :dod_verifier,
       ~s({"verdict":"fail","evidence":["lib/x.ex:9"],"blocking":["missing test"],"warnings":[],"rationale":"no"})}
    ])

    {agg, [verdict]} =
      AdversarialReviewGate.run(%{epic_id: "e1", artifact: "diff..."}, task_supervisor: sup)

    assert agg == :fail
    assert verdict.verdict == :fail
    assert "missing test" in verdict.blocking
  end
end
