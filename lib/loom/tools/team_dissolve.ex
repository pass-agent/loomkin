defmodule Loom.Tools.TeamDissolve do
  @moduledoc "Dissolve a team, stopping all agents and cleaning up."

  use Jido.Action,
    name: "team_dissolve",
    description:
      "Dissolve a team: stop all agents, clean up state, and broadcast dissolution.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID to dissolve"]
    ]

  import Loom.Tool, only: [param!: 2]

  alias Loom.Teams.Manager

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)

    agents = Manager.list_agents(team_id)
    agent_names = Enum.map(agents, & &1.name)

    :ok = Manager.dissolve_team(team_id)

    summary = """
    Team #{team_id} dissolved.
    Stopped agents: #{Enum.join(agent_names, ", ")}
    """

    {:ok, %{result: String.trim(summary)}}
  end
end
