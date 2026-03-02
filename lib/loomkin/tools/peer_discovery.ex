defmodule Loomkin.Tools.PeerDiscovery do
  @moduledoc "Broadcast a discovery to the team."

  use Jido.Action,
    name: "peer_discovery",
    description:
      "Share a discovery with the team. Stored in the shared context " <>
        "and broadcast to all agents on the context topic.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      content: [type: :string, required: true, doc: "Discovery content"],
      type: [type: :string, doc: "Discovery type (default: discovery)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.{Comms, Context}

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    content = param!(params, :content)
    type_str = param(params, :type) || "discovery"
    from = param!(context, :agent_name)

    discovery = %{from: from, type: type_str, content: content}
    Context.add_discovery(team_id, discovery)
    Comms.broadcast_context(team_id, discovery)

    {:ok, %{result: "Discovery broadcast to team: #{String.slice(content, 0, 80)}"}}
  end
end
