defmodule Loomkin.Tools.PeerAskQuestion do
  @moduledoc "Ask a question to the team."

  use Jido.Action,
    name: "peer_ask_question",
    description:
      "Ask a question to the team. The question is routed to a specific agent (if named) " <>
        "or broadcast to all. Answers are delivered back to you asynchronously. " <>
        "The system automatically enriches questions with relevant context from keepers.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      question: [type: :string, required: true, doc: "The question to ask"],
      target: [type: :string, doc: "Specific agent to ask (omit to broadcast)"],
      context: [type: :string, doc: "Additional context for the question"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.QueryRouter

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    question = param!(params, :question)
    target = param(params, :target)
    extra_context = param(params, :context)
    from = param!(context, :agent_name)

    full_question =
      if extra_context do
        "#{question}\n\nContext from #{from}: #{extra_context}"
      else
        question
      end

    opts = if target, do: [target: target], else: []

    case QueryRouter.ask(team_id, from, full_question, opts) do
      {:ok, query_id} ->
        target_desc = if target, do: target, else: "all agents"

        {:ok,
         %{
           result:
             "Question sent to #{target_desc}. Query ID: #{query_id}. " <>
               "The answer will be delivered to you when available.",
           query_id: query_id
         }}

      {:error, reason} ->
        {:error, "Failed to send question: #{inspect(reason)}"}
    end
  end
end
