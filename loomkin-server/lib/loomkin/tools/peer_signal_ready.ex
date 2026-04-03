defmodule Loomkin.Tools.PeerSignalReady do
  @moduledoc "Agent-initiated readiness signal for coordination and rendezvous."

  use Jido.Action,
    name: "peer_signal_ready",
    description:
      "Signal that this agent is ready and available. " <>
        "Optionally signals readiness for a specific rendezvous barrier.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      agent_name: [type: :string, required: true, doc: "Name of the signaling agent"],
      ready_for: [type: :string, doc: "What the agent is ready for (e.g. new_task, review)"],
      rendezvous_id: [type: :string, doc: "Rendezvous barrier ID to signal arrival at"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    agent_name = param!(params, :agent_name)
    ready_for = param(params, :ready_for)
    rendezvous_id = param(params, :rendezvous_id)

    # Publish agent ready signal
    signal =
      Loomkin.Signals.Agent.Ready.new!(%{
        agent_name: to_string(agent_name),
        team_id: team_id,
        ready_for: ready_for,
        rendezvous_id: rendezvous_id
      })

    Loomkin.Signals.publish(signal)

    # If rendezvous_id is present, signal arrival at the barrier
    result =
      if rendezvous_id do
        case Loomkin.Teams.Rendezvous.signal_ready(team_id, rendezvous_id, agent_name) do
          {:ok, :arrived} ->
            "Agent #{agent_name} signaled ready and arrived at rendezvous #{rendezvous_id}"

          {:ok, :completed} ->
            "Agent #{agent_name} arrived at rendezvous #{rendezvous_id} — all agents present, barrier completed"

          {:error, reason} ->
            "Agent #{agent_name} signaled ready. Rendezvous error: #{inspect(reason)}"
        end
      else
        "Agent #{agent_name} signaled ready" <>
          if(ready_for, do: " for: #{ready_for}", else: "")
      end

    {:ok, %{result: result}}
  end
end
