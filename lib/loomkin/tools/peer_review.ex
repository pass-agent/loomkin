defmodule Loomkin.Tools.PeerReview do
  @moduledoc "Request a code review from the team."

  use Jido.Action,
    name: "peer_review",
    description:
      "Broadcast a code review request to the team with file path, diff, " <>
        "and an optional question.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      file_path: [type: :string, required: true, doc: "Path to the file being reviewed"],
      diff: [type: :string, required: true, doc: "The diff or changes to review"],
      question: [type: :string, doc: "Specific question for reviewers"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Comms

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    file_path = param!(params, :file_path)
    diff = param!(params, :diff)
    question = param(params, :question)
    from = param!(context, :agent_name)

    payload = %{file: file_path, changes: diff, question: question}
    Comms.broadcast(team_id, {:request_review, from, payload})

    {:ok, %{result: "Review request broadcast for #{file_path}."}}
  end
end
