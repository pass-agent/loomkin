defmodule Loomkin.Tools.PeerMessage do
  @moduledoc "Send a direct message to a peer agent."

  use Jido.Action,
    name: "peer_message",
    description:
      "Send a direct message to another agent on the team. " <>
        "The message is delivered via PubSub to the target agent's topic.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      to: [type: :string, required: true, doc: "Name of the recipient agent"],
      content: [type: :string, required: true, doc: "Message content"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Comms

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    to = param!(params, :to)
    content = param!(params, :content)
    from = param!(context, :agent_name)

    Comms.send_to(team_id, to, {:peer_message, from, content})
    {:ok, %{result: "Message sent to #{to}."}}
  end
end
