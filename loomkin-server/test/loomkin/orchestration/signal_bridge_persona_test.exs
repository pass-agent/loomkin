defmodule Loomkin.Orchestration.SignalBridgePersonaTest do
  @moduledoc """
  Verifies that the SignalBridge enriches every translated Jido.Signal with
  the resolved persona from Loomkin.Orchestration.Personas.
  """
  use ExUnit.Case, async: false

  alias Loomkin.Signals

  setup do
    sub = Signals.subscribe("session.orchestration.**")
    on_exit(fn -> Signals.unsubscribe(sub) end)
    %{sub: sub}
  end

  test "epic phase_entered event carries the Researcher persona" do
    epic_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.epic",
      {"orchestration.epic",
       %{epic_id: epic_id, event: {:phase_entered, :research}, session_id: nil}}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      type: "session.orchestration.phase",
                      data: %{
                        subtype: :epic,
                        epic_id: ^epic_id,
                        persona: %{name: "Researcher"}
                      }
                    }},
                   1_000
  end

  test "gate verdict carries the Plan Council persona" do
    epic_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.gate",
      {"orchestration.gate",
       %{
         epic_id: epic_id,
         event: {:gate_verdict, :plan_review, :pass, 3},
         session_id: nil
       }}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      type: "session.orchestration.phase",
                      data: %{
                        subtype: :gate,
                        persona: %{name: "Plan Council"}
                      }
                    }},
                   1_000
  end

  test "work_unit completed event carries the Committer persona" do
    wu_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.work_unit",
      {"orchestration.work_unit", %{work_unit_id: wu_id, event: :completed, session_id: nil}}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      data: %{
                        subtype: :work_unit,
                        work_unit_id: ^wu_id,
                        persona: %{name: "Committer", icon: "✅"}
                      }
                    }},
                   1_000
  end

  test "knowledge event always carries the Curator persona" do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.knowledge",
      {"orchestration.knowledge", %{event: {:fact_added, "x"}, session_id: nil}}
    )

    assert_receive {:signal,
                    %Jido.Signal{
                      data: %{
                        subtype: :knowledge,
                        persona: %{name: "Curator"}
                      }
                    }},
                   1_000
  end

  test "unknown event still produces a persona (falls back to System)" do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "orchestration.epic",
      {"orchestration.epic",
       %{epic_id: Ecto.UUID.generate(), event: :totally_unknown, session_id: nil}}
    )

    assert_receive {:signal, %Jido.Signal{data: %{persona: %{name: "System"}}}},
                   1_000
  end
end
