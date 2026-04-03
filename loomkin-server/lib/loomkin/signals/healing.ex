defmodule Loomkin.Signals.Healing do
  @moduledoc "Healing-domain signals: session lifecycle, diagnosis, fix, completion."

  defmodule SessionStarted do
    use Jido.Signal,
      type: "healing.session.started",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        classification: [type: :map, required: true]
      ]
  end

  defmodule DiagnosisComplete do
    use Jido.Signal,
      type: "healing.diagnosis.complete",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        root_cause: [type: :string, required: true],
        confidence: [type: :float, required: true]
      ]
  end

  defmodule FixApplied do
    use Jido.Signal,
      type: "healing.fix.applied",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        files_changed: [type: {:list, :string}, required: true]
      ]
  end

  defmodule SessionComplete do
    use Jido.Signal,
      type: "healing.session.complete",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        outcome: [type: {:in, [:healed, :escalated, :timed_out, :cancelled]}, required: true],
        duration_ms: [type: :integer, required: true]
      ]
  end
end
