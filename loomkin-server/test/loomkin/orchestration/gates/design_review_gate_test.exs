defmodule Loomkin.Orchestration.Gates.DesignReviewGateTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Gates.DesignReviewGate
  alias Loomkin.Orchestration.LLM.Stub

  setup do
    sup = String.to_atom("DesignReviewSup.#{System.unique_integer([:positive])}")
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

  defp pass_for(reviewer) do
    {:by_reviewer, reviewer,
     ~s({"verdict":"pass","evidence":["design:1"],"blocking":[],"warnings":[],"rationale":"ok"})}
  end

  test "5 reviewers run in parallel under 1s with scripted responses", %{sup: sup} do
    Stub.queue([
      pass_for(:pm),
      pass_for(:architect),
      pass_for(:designer),
      pass_for(:security),
      pass_for(:cto)
    ])

    {time_us, {agg, verdicts}} =
      :timer.tc(fn ->
        DesignReviewGate.run(%{epic_id: "e1", artifact: "design body"}, task_supervisor: sup)
      end)

    assert agg == :pass
    assert length(verdicts) == 5
    assert div(time_us, 1000) < 1000
  end
end
