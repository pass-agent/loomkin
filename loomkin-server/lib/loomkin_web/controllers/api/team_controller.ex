defmodule LoomkinWeb.Api.TeamController do
  use LoomkinWeb, :controller

  alias Loomkin.Teams.Context, as: TeamContext

  action_fallback LoomkinWeb.Api.FallbackController

  @doc "GET /api/v1/teams/:team_id"
  def show(conn, %{"team_id" => team_id}) do
    agents = TeamContext.list_agents(team_id)
    tasks = TeamContext.list_cached_tasks(team_id)

    json(conn, %{
      team: %{
        id: team_id,
        agents: agents,
        tasks: tasks
      }
    })
  end

  @doc "GET /api/v1/teams/:team_id/agents"
  def agents(conn, %{"team_id" => team_id}) do
    agents = TeamContext.list_agents(team_id)
    json(conn, %{agents: agents})
  end
end
