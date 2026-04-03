defmodule Loomkin.Tools.PeerNegotiateTask do
  @moduledoc "Agent tool to submit a counter-proposal for a task assignment."

  use Jido.Action,
    name: "peer_negotiate_task",
    description:
      "Submit a counter-proposal for a task assignment. " <>
        "Use this when you believe a different approach or assignment would be better.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      agent_name: [type: :string, required: true, doc: "Name of the responding agent"],
      task_id: [type: :string, required: true, doc: "ID of the task being negotiated"],
      response: [
        type: :string,
        required: true,
        doc: "Response type: 'accept', 'decline', or 'negotiate'"
      ],
      reason: [
        type: :string,
        doc: "Reason for counter-proposal (required if response is negotiate)"
      ],
      counter_proposal: [
        type: :string,
        doc: "Counter-proposal description (required if response is negotiate)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Negotiation

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    response_type = param!(params, :response)
    reason = param(params, :reason)
    counter_proposal = param(params, :counter_proposal)

    response =
      case response_type do
        "accept" ->
          :accept

        "decline" ->
          :decline

        "negotiate" ->
          {:negotiate, reason || "", counter_proposal || ""}

        _ ->
          {:error,
           "Unknown response type: #{response_type}. Use 'accept', 'decline', or 'negotiate'."}
      end

    case response do
      {:error, msg} ->
        {:error, msg}

      _ ->
        case Negotiation.respond(team_id, task_id, response) do
          :ok ->
            {:ok,
             %{result: "Negotiation response '#{response_type}' submitted for task #{task_id}"}}

          {:error, err} ->
            {:error, "Negotiation response failed: #{inspect(err)}"}
        end
    end
  end
end
