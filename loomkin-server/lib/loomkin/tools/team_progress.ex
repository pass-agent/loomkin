defmodule Loomkin.Tools.TeamProgress do
  @moduledoc "Check team status: agents, tasks, claims, budget."

  use Jido.Action,
    name: "team_progress",
    description:
      "Get a formatted summary of team progress including agents, tasks, " <>
        "region claims, and budget usage.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Context
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.RateLimiter
  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)

    agents = safe_list_agents(team_id)
    tasks = Tasks.list_all(team_id)
    claims = Context.list_all_claims(team_id)
    budget = RateLimiter.get_budget(team_id)

    agents_section =
      case agents do
        :error ->
          "  (unavailable — check logs)"

        [] ->
          "  (none)"

        agents ->
          Enum.map_join(agents, "\n", fn a ->
            "  - #{Map.get(a, :name, "?")} (#{Map.get(a, :role, "?")}): #{Map.get(a, :status, "?")}"
          end)
      end

    tasks_section =
      if tasks == [] do
        "  (none)"
      else
        Enum.map_join(tasks, "\n", fn t ->
          owner = t.owner || "unassigned"
          "  - [#{t.status}] #{t.title} (#{owner}, p#{t.priority})"
        end)
      end

    claims_section =
      if claims == [] do
        "  (none)"
      else
        Enum.map_join(claims, "\n", fn c ->
          "  - #{c.agent}: #{c.path} #{inspect(c.region)}"
        end)
      end

    budget_section =
      "  Spent: $#{:erlang.float_to_binary(budget.spent / 1, decimals: 4)} / $#{:erlang.float_to_binary(budget.limit / 1, decimals: 2)}"

    summary = """
    Team: #{team_id}

    Agents:
    #{agents_section}

    Tasks (#{length(tasks)} total):
    #{tasks_section}

    Region Claims:
    #{claims_section}

    Budget:
    #{budget_section}
    """

    {:ok, %{result: String.trim(summary)}}
  end

  defp safe_list_agents(team_id) do
    Manager.list_agents(team_id)
  rescue
    _e ->
      :error
  end
end
