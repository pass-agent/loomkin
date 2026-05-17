defmodule Loomkin.Orchestration.IntentClassifierTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.IntentClassifier
  alias Loomkin.Orchestration.LLM.Stub

  setup do
    start_supervised!(Stub)
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  test "rule-decided messages skip the LLM" do
    {intent, {:rule, n}, _} = IntentClassifier.classify("hi")
    assert intent == :fast_chat
    assert n == 2
  end

  test "ambiguous messages call the LLM fallback" do
    Stub.queue([
      {:by_reviewer, :intent_classifier,
       ~s({"intent":"complex_task","confidence":"high","rationale":"sounds like work"})}
    ])

    {intent, via, reason} =
      IntentClassifier.classify(
        "I'm thinking about the architecture and want to talk through tradeoffs"
      )

    assert intent == :complex_task
    assert via == :llm
    assert reason =~ "llm:high"
  end

  test "LLM failure fails safe to :complex_task" do
    # No queued response → Stub returns {:error, :no_stub_response}
    {intent, via, reason} =
      IntentClassifier.classify(
        "I'm thinking about the architecture and want to talk through tradeoffs"
      )

    assert intent == :complex_task
    assert via == :llm
    assert reason =~ "fail-safe to complex"
  end

  test "telemetry is emitted on every classification" do
    me = self()

    :telemetry.attach(
      "test-intent-tel",
      [:loomkin, :orchestration, :intent, :classified],
      fn _e, m, meta, _ -> send(me, {:telemetry, m, meta}) end,
      nil
    )

    {_intent, _via, _reason} = IntentClassifier.classify("hello")
    assert_receive {:telemetry, %{duration_ms: _}, %{intent: :fast_chat, via: {:rule, 3}}}

    :telemetry.detach("test-intent-tel")
  end
end
