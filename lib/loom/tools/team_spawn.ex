defmodule Loom.Tools.TeamSpawn do
  @moduledoc "Spawn a team with agents."

  use Jido.Action,
    name: "team_spawn",
    description:
      "Create a new agent team and spawn agents with specified roles. " <>
        "Optionally use a template name to spawn a pre-configured team. " <>
        "Returns a team status summary with team_id and agent list.",
    schema: [
      team_name: [type: :string, required: true, doc: "Human-readable team name"],
      roles: [type: {:list, :map}, doc: "List of %{name, role} maps for agents to spawn (ignored if template is set)"],
      template: [type: :string, doc: "Template name from .loom.toml to use instead of explicit roles"],
      project_path: [type: :string, doc: "Path to the project for agents to work on"]
    ]

  import Loom.Tool, only: [param!: 2, param: 2]

  alias Loom.Teams.{Manager, Templates}

  @impl true
  def run(params, context) do
    team_name = param!(params, :team_name)
    template = param(params, :template)
    project_path = param(params, :project_path) || param(context, :project_path)

    if template do
      spawn_from_template(team_name, template, project_path)
    else
      roles = param!(params, :roles)
      spawn_from_roles(team_name, roles, project_path)
    end
  end

  defp spawn_from_template(team_name, template_name, project_path) do
    case Templates.spawn_from_template(team_name, template_name, project_path: project_path) do
      {:ok, team_id, agents} ->
        results =
          Enum.map(agents, fn a ->
            case a.status do
              :ok -> "  - #{a.name} (#{a.role}): spawned"
              {:error, reason} -> "  - #{a.name} (#{a.role}): failed - #{inspect(reason)}"
            end
          end)

        summary = """
        Team "#{team_name}" created from template "#{template_name}" (id: #{team_id})
        Agents:
        #{Enum.join(results, "\n")}
        """

        {:ok, %{result: String.trim(summary), team_id: team_id}}

      {:error, :template_not_found} ->
        {:error, "Template '#{template_name}' not found in .loom.toml"}

      {:error, reason} ->
        {:error, "Failed to create team from template: #{inspect(reason)}"}
    end
  end

  defp spawn_from_roles(team_name, roles, project_path) do
    {:ok, team_id} = Manager.create_team(name: team_name, project_path: project_path)

    results =
      Enum.map(roles, fn role_map ->
        name = Map.get(role_map, :name) || Map.get(role_map, "name")
        role = Map.get(role_map, :role) || Map.get(role_map, "role")
        role_atom =
          if is_binary(role) do
            try do
              String.to_existing_atom(role)
            rescue
              ArgumentError -> nil
            end
          else
            role
          end

        if is_nil(role_atom) do
          "  - #{name} (#{role}): failed - unknown role"
        else
          case Manager.spawn_agent(team_id, name, role_atom, project_path: project_path) do
            {:ok, _pid} -> "  - #{name} (#{role}): spawned"
            {:error, reason} -> "  - #{name} (#{role}): failed - #{inspect(reason)}"
          end
        end
      end)

    summary = """
    Team "#{team_name}" created (id: #{team_id})
    Agents:
    #{Enum.join(results, "\n")}
    """

    {:ok, %{result: String.trim(summary), team_id: team_id}}
  end
end
