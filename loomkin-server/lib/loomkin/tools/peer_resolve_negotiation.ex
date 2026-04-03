defmodule Loomkin.Tools.PeerResolveNegotiation do
  @moduledoc "Lead tool to resolve an active negotiation for a task assignment."

  use Jido.Action,
    name: "peer_resolve_negotiation",
    description:
      "Resolve a task assignment negotiation. " <>
        "Use this as a lead to accept the agent's counter-proposal, override it, or reassign.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      agent_name: [type: :string, required: true, doc: "Name of the lead resolving"],
      task_id: [type: :string, required: true, doc: "ID of the task being negotiated"],
      resolution: [
        type: :string,
        required: true,
        doc: "Resolution: 'accept_negotiation', 'override', or 'reassign'"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Negotiation

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    resolution_str = param!(params, :resolution)

    resolution =
      case resolution_str do
        "accept_negotiation" ->
          :accept_negotiation

        "override" ->
          :override

        "reassign" ->
          :reassign

        _ ->
          {:error,
           "Unknown resolution: #{resolution_str}. Use 'accept_negotiation', 'override', or 'reassign'."}
      end

    case resolution do
      {:error, msg} ->
        {:error, msg}

      _ ->
        case Negotiation.resolve(team_id, task_id, resolution) do
          :ok ->
            {:ok, %{result: "Negotiation for task #{task_id} resolved with: #{resolution_str}"}}

          {:error, err} ->
            {:error, "Negotiation resolution failed: #{inspect(err)}"}
        end
    end
  end
end
