defmodule Loomkin.Orchestration.SessionBridgeTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.SessionBridge
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

  defp session_state, do: %{id: "sess-1", team_id: nil, workspace_id: nil}

  test "fast_chat routes to LitePipeline (returns :legacy in skeleton mode)" do
    assert {:legacy, _} = SessionBridge.dispatch(session_state(), "hello")
  end

  test "tool_use routes to ShortPipeline (returns :legacy in skeleton mode)" do
    assert {:legacy, _} = SessionBridge.dispatch(session_state(), "run the tests")
  end

  test "telemetry is emitted on dispatch" do
    me = self()

    :telemetry.attach(
      "test-bridge-tel",
      [:loomkin, :orchestration, :session_bridge, :dispatched],
      fn _e, _m, meta, _ -> send(me, {:dispatched, meta}) end,
      nil
    )

    _ = SessionBridge.dispatch(session_state(), "hi")
    assert_receive {:dispatched, %{intent: :fast_chat}}

    :telemetry.detach("test-bridge-tel")
  end
end
