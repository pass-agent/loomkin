defmodule Loomkin.Tools.ListTeams do
  @moduledoc "Discover the team hierarchy: siblings, children, parent, and their agents."

  use Jido.Action,
    name: "list_teams",
    description:
      "List sibling teams, child teams, or parent team and their agents. " <>
        "Use this to discover cross-team communication targets before using cross_team_query.",
    schema: [
      team_id: [type: :string, required: true, doc: "Your current team ID"],
      scope: [
        type: :string,
        doc: "Which teams to list: 'siblings', 'children', 'parent', or 'all' (default: 'all')"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Teams.Manager

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    scope = param(params, :scope, "all")

    sections = build_sections(team_id, scope)

    if sections == [] do
      {:ok, %{result: "No related teams found. This is a standalone team."}}
    else
      result = Enum.join(sections, "\n\n")
      {:ok, %{result: result}}
    end
  end

  defp build_sections(team_id, "parent"), do: [parent_section(team_id)] |> reject_nil()
  defp build_sections(team_id, "siblings"), do: [siblings_section(team_id)] |> reject_nil()
  defp build_sections(team_id, "children"), do: [children_section(team_id)] |> reject_nil()

  defp build_sections(team_id, _all) do
    [
      parent_section(team_id),
      siblings_section(team_id),
      children_section(team_id)
    ]
    |> reject_nil()
  end

  defp parent_section(team_id) do
    case Manager.get_parent_team(team_id) do
      {:ok, parent_id} ->
        name = Manager.get_team_name(parent_id) || parent_id
        agents = format_agents(parent_id)
        "## Parent Team\n- #{name} (#{parent_id})#{agents}"

      :none ->
        nil
    end
  end

  defp siblings_section(team_id) do
    case Manager.get_sibling_teams(team_id) do
      {:ok, []} ->
        nil

      {:ok, siblings} ->
        entries =
          Enum.map_join(siblings, "\n", fn sib_id ->
            name = Manager.get_team_name(sib_id) || sib_id
            agents = format_agents(sib_id)
            "- #{name} (#{sib_id})#{agents}"
          end)

        "## Sibling Teams\n#{entries}"

      :none ->
        nil
    end
  end

  defp children_section(team_id) do
    case Manager.get_child_teams(team_id) do
      [] ->
        nil

      children ->
        entries =
          Enum.map_join(children, "\n", fn child_id ->
            name = Manager.get_team_name(child_id) || child_id
            agents = format_agents(child_id)
            "- #{name} (#{child_id})#{agents}"
          end)

        "## Child Teams\n#{entries}"
    end
  end

  defp format_agents(team_id) do
    case Manager.list_agents(team_id) do
      [] ->
        ""

      agents ->
        agent_list =
          Enum.map_join(agents, ", ", fn a ->
            "#{a.name} (#{a.role})"
          end)

        "\n  Agents: #{agent_list}"
    end
  end

  defp reject_nil(list), do: Enum.reject(list, &is_nil/1)
end
