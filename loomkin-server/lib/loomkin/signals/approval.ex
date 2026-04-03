defmodule Loomkin.Signals.Approval do
  @moduledoc "Approval gate signals: requested when an agent blocks for human approval, resolved when the gate closes."

  defmodule Requested do
    use Jido.Signal,
      type: "agent.approval.requested",
      schema: [
        gate_id: [type: :string, required: true, doc: "Unique identifier for this approval gate"],
        agent_name: [type: :string, required: true, doc: "Name of the requesting agent"],
        team_id: [type: :string, required: true, doc: "Team the agent belongs to"],
        question: [type: :string, required: true, doc: "The question presented to the approver"],
        timeout_ms: [type: :integer, required: false, doc: "Gate timeout in milliseconds"]
      ]
  end

  defmodule Resolved do
    use Jido.Signal,
      type: "agent.approval.resolved",
      schema: [
        gate_id: [type: :string, required: true, doc: "Unique identifier for this approval gate"],
        agent_name: [type: :string, required: true, doc: "Name of the requesting agent"],
        team_id: [type: :string, required: true, doc: "Team the agent belongs to"],
        outcome: [
          type: :atom,
          required: true,
          doc: "Resolution outcome: :approved | :denied | :timeout"
        ]
      ]
  end
end
