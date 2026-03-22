defmodule Loomkin.Tools.PeerForwardQuestion do
  @moduledoc "Forward a question to another agent with enrichment context."

  use Jido.Action,
    name: "peer_forward_question",
    description:
      "Forward a question to another agent, adding your knowledge as enrichment context.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query_id: [type: :string, required: true, doc: "The query ID to forward"],
      target: [type: :string, required: true, doc: "Name of the agent to forward to"],
      enrichment: [
        type: :string,
        required: true,
        doc: "What you know about this question (added as context for the next agent)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.QueryRouter

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    query_id = param!(params, :query_id)
    target = param!(params, :target)
    enrichment = param!(params, :enrichment)
    from = param!(context, :agent_name)

    # Validate the query belongs to this team before forwarding
    with {:ok, query} <- QueryRouter.get_query(query_id),
         true <- query.team_id == team_id do
      case QueryRouter.forward(query_id, from, target, enrichment) do
        :ok ->
          {:ok, %{result: "Question forwarded to #{target} with enrichment."}}

        {:error, :not_found} ->
          {:ok, %{result: "Query #{query_id} not found (may have expired)."}}

        {:error, :max_hops_reached} ->
          {:ok,
           %{result: "Maximum forwarding hops reached. Consider answering with what you know."}}
      end
    else
      {:error, :not_found} ->
        {:ok, %{result: "Query #{query_id} not found (may have expired)."}}

      false ->
        {:ok, %{result: "Query #{query_id} does not belong to this team."}}
    end
  end
end
