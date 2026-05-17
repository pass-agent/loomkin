defmodule Loomkin.Orchestration.SignalBridgeTest do
  @moduledoc """
  Verifies the SignalBridge translates orchestration.* PubSub events into
  Jido.Signal messages of type "session.orchestration.phase".
  """
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.SignalBridge
  alias Loomkin.Signals

  setup do
    # The application supervisor already started a SignalBridge. We need this
    # test process to receive the translated Jido.Signal events.
    sub = Signals.subscribe("session.orchestration.**")
    on_exit(fn -> Signals.unsubscribe(sub) end)
    %{sub: sub}
  end

  test "epic event on PubSub becomes a typed signal on the bus" do
    epic_id = Ecto.UUID.generate()

    payload = %{
      epic_id: epic_id,
      event: {:phase_entered, :plan},
      session_id: nil
    }

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.epic",
      {"orchestration.epic", payload}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      type: "session.orchestration.phase",
                      data: %{subtype: :epic, epic_id: ^epic_id}
                    }},
                   1_000
  end

  test "work_unit event becomes a typed signal" do
    wu_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.work_unit",
      {"orchestration.work_unit", %{work_unit_id: wu_id, event: :validate_pass, session_id: nil}}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      type: "session.orchestration.phase",
                      data: %{subtype: :work_unit, work_unit_id: ^wu_id}
                    }},
                   1_000
  end

  test "unknown payload shape is ignored without crashing" do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.epic",
      {"orchestration.epic", "garbage"}
    )

    Process.sleep(50)
    # SignalBridge still alive
    assert Process.alive?(Process.whereis(SignalBridge))
  end

  test "diff payload on work_unit topic becomes a session.orchestration.diff signal" do
    wu_id = Ecto.UUID.generate()

    payload = %{
      work_unit_id: wu_id,
      event: :diff,
      sha: "abc1234567890",
      stats: %{additions: 5, deletions: 2, files: 1},
      files: [%{path: "lib/x.ex", additions: 5, deletions: 2}],
      patch_excerpt: "diff --git a/lib/x.ex …",
      session_id: nil
    }

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.work_unit",
      {"orchestration.work_unit", payload}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      type: "session.orchestration.diff",
                      data: %{
                        subtype: :work_unit,
                        work_unit_id: ^wu_id,
                        sha: "abc1234567890",
                        stats: %{additions: 5, deletions: 2, files: 1}
                      }
                    }},
                   1_000
  end
end
