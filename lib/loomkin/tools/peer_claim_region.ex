defmodule Loomkin.Tools.PeerClaimRegion do
  @moduledoc "Claim a file region to prevent edit conflicts."

  use Jido.Action,
    name: "peer_claim_region",
    description:
      "Claim a line region of a file so other agents avoid editing it. " <>
        "Returns :ok or conflict information if another agent holds the region.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      path: [type: :string, required: true, doc: "File path (relative to project root)"],
      start_line: [type: :integer, required: true, doc: "Start line number"],
      end_line: [type: :integer, required: true, doc: "End line number"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Context

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    path = param!(params, :path)
    start_line = param!(params, :start_line)
    end_line = param!(params, :end_line)
    agent_name = param!(context, :agent_name)

    region = {:lines, start_line, end_line}

    case Context.claim_region(team_id, agent_name, path, region) do
      :ok ->
        {:ok, %{result: "Claimed #{path} lines #{start_line}-#{end_line}."}}

      {:conflict, other_agent, other_region} ->
        {:ok, %{result: "Conflict: #{other_agent} holds #{path} #{inspect(other_region)}. Choose a different region."}}
    end
  end
end
