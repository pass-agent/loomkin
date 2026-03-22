defmodule Loomkin.Tools.CreateRendezvous do
  @moduledoc "Lead-only tool for creating synchronization barriers."

  use Jido.Action,
    name: "create_rendezvous",
    description:
      "Create a synchronization barrier that waits for specified agents to signal ready. " <>
        "Once all required agents arrive, the on_complete_message is broadcast to the team. " <>
        "Lead-only tool.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      name: [type: :string, required: true, doc: "Human-readable name for this rendezvous"],
      required_agents: [
        type: :string,
        required: true,
        doc: "Comma-separated list of agent names that must arrive"
      ],
      on_complete_message: [
        type: :string,
        required: true,
        doc: "Message to broadcast when all agents arrive"
      ],
      timeout_minutes: [type: :integer, doc: "Timeout in minutes (default 5)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Rendezvous

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    name = param!(params, :name)
    agents_str = param!(params, :required_agents)
    on_complete = param!(params, :on_complete_message)
    timeout_min = param(params, :timeout_minutes) || 5

    required_agents =
      agents_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if required_agents == [] do
      {:error, "required_agents must contain at least one agent name"}
    else
      case Rendezvous.create_barrier(team_id, name, required_agents, on_complete,
             timeout_minutes: timeout_min
           ) do
        {:ok, rendezvous_id} ->
          summary = """
          Rendezvous created:
            ID: #{rendezvous_id}
            Name: #{name}
            Required agents: #{Enum.join(required_agents, ", ")}
            Timeout: #{timeout_min} minutes
          Agents should use peer_signal_ready with rendezvous_id to signal arrival.
          """

          {:ok, %{result: String.trim(summary), rendezvous_id: rendezvous_id}}

        {:error, reason} ->
          {:error, "Failed to create rendezvous: #{inspect(reason)}"}
      end
    end
  end
end
