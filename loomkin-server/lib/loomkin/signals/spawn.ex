defmodule Loomkin.Signals.Spawn do
  @moduledoc "Spawn gate signals: requested when an agent blocks for human spawn approval, resolved when the gate closes."

  defmodule GateRequested do
    use Jido.Signal,
      type: "agent.spawn.gate.requested",
      schema: [
        gate_id: [type: :string, required: true, doc: "Unique identifier for this spawn gate"],
        agent_name: [type: :string, required: true, doc: "Name of the requesting agent"],
        team_id: [type: :string, required: true, doc: "Team the agent belongs to"],
        team_name: [type: :string, required: true, doc: "Name of the team to be spawned"],
        purpose: [
          type: :string,
          required: false,
          doc: "Brief description of what the team will do, shown in the approval UI"
        ],
        roles: [
          type: {:list, :map},
          required: true,
          doc: "List of role maps describing the agents in the new team"
        ],
        estimated_cost: [
          type: :float,
          required: true,
          doc: "Estimated cost in USD for the spawn"
        ],
        limit_warning: [
          type: :atom,
          required: false,
          doc: "Warning if spawn would approach limits: :depth | :agents | nil"
        ],
        timeout_ms: [
          type: :integer,
          required: false,
          doc: "Gate timeout in milliseconds"
        ],
        auto_approve_spawns: [
          type: :boolean,
          required: false,
          doc: "Current auto-approve setting for rendering checkbox state"
        ]
      ]
  end

  defmodule GateResolved do
    use Jido.Signal,
      type: "agent.spawn.gate.resolved",
      schema: [
        gate_id: [type: :string, required: true, doc: "Unique identifier for this spawn gate"],
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
