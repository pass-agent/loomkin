defmodule Loomkin.Tools.CrossTeamQuery do
  @moduledoc "Ask a question to agents in a sibling, parent, or child team."

  use Jido.Action,
    name: "cross_team_query",
    description:
      "Ask a question to agents in another team (sibling, parent, or child). " <>
        "The answer arrives asynchronously via query_answer. " <>
        "Use list_teams first to discover available teams.",
    schema: [
      team_id: [type: :string, required: true, doc: "Your current team ID"],
      target_team: [
        type: :string,
        doc:
          "Target team ID. Use list_teams to discover available teams. " <>
            "Defaults to parent team if omitted."
      ],
      question: [type: :string, required: true, doc: "The question to ask"],
      target_agent: [type: :string, doc: "Specific agent to ask (omit to broadcast to all)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.QueryRouter

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    question = param!(params, :question)
    target_team = param(params, :target_team)
    target_agent = param(params, :target_agent)
    from = param!(context, :agent_name)

    target_team_id = resolve_target_team(team_id, target_team)

    case target_team_id do
      nil ->
        {:error, "Could not resolve target team. Use list_teams to discover available teams."}

      ^team_id ->
        {:error, "Target team is your own team. Use peer_ask_question for intra-team queries."}

      target_id ->
        opts = if target_agent, do: [target: target_agent], else: []

        case QueryRouter.ask_cross_team(team_id, target_id, from, question, opts) do
          {:ok, query_id} ->
            target_desc = if target_agent, do: target_agent, else: "all agents"
            team_name = Manager.get_team_name(target_id) || target_id

            {:ok,
             %{
               result:
                 "Cross-team question sent to #{target_desc} in team '#{team_name}'. " <>
                   "Query ID: #{query_id}. The answer will arrive asynchronously.",
               query_id: query_id
             }}

          {:error, reason} ->
            {:error, "Failed to send cross-team question: #{inspect(reason)}"}
        end
    end
  end

  defp resolve_target_team(_team_id, target) when is_binary(target) and target != "", do: target

  defp resolve_target_team(team_id, _) do
    case Manager.get_parent_team(team_id) do
      {:ok, parent_id} -> parent_id
      :error -> nil
    end
  end
end
