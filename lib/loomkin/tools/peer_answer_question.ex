defmodule Loomkin.Tools.PeerAnswerQuestion do
  @moduledoc "Answer a question that was routed to you."

  use Jido.Action,
    name: "peer_answer_question",
    description:
      "Answer a question that was routed to you. " <>
        "The answer is delivered back to the original asker.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query_id: [
        type: :string,
        required: true,
        doc: "The query ID from the question you received"
      ],
      answer: [type: :string, required: true, doc: "Your answer to the question"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.QueryRouter

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    query_id = param!(params, :query_id)
    answer = param!(params, :answer)
    from = param!(context, :agent_name)

    # Validate the query belongs to this team before answering
    with {:ok, query} <- QueryRouter.get_query(query_id),
         true <- query.team_id == team_id do
      case QueryRouter.answer(query_id, from, answer) do
        :ok ->
          {:ok, %{result: "Answer delivered for query #{query_id}."}}

        {:error, :not_found} ->
          {:ok, %{result: "Query #{query_id} not found (may have expired)."}}
      end
    else
      {:error, :not_found} ->
        {:ok, %{result: "Query #{query_id} not found (may have expired)."}}

      false ->
        {:ok, %{result: "Query #{query_id} does not belong to this team."}}
    end
  end
end
