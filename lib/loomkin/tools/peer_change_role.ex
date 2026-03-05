defmodule Loomkin.Tools.PeerChangeRole do
  @moduledoc "Request a role change for a peer agent (or self)."

  use Jido.Action,
    name: "peer_change_role",
    description:
      "Change the role of an agent on the team. Can target self or a peer agent. " <>
        "Valid roles: lead, researcher, coder, reviewer, tester.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      target: [type: :string, required: true, doc: "Name of the agent to change (can be self)"],
      new_role: [
        type: :string,
        required: true,
        doc: "New role name (lead, researcher, coder, reviewer, tester)"
      ],
      require_approval: [type: :boolean, doc: "If true, request lead approval before changing"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Teams.Manager

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    target = param!(params, :target)
    new_role_str = param!(params, :new_role)
    require_approval = param(params, :require_approval, false)

    new_role =
      try do
        String.to_existing_atom(new_role_str)
      rescue
        ArgumentError -> nil
      end

    if is_nil(new_role) do
      {:error, "Unknown role: #{new_role_str}"}
    else
      case Manager.find_agent(team_id, target) do
        {:ok, pid} ->
          opts = if require_approval, do: [require_approval: true], else: []

          case Loomkin.Teams.Agent.change_role(pid, new_role, opts) do
            :ok ->
              {:ok, %{result: "Role of #{target} changed to #{new_role}."}}

            {:error, :unknown_role} ->
              {:error, "Unknown role: #{new_role_str}"}
          end

        :error ->
          {:error, "Agent #{target} not found in team #{team_id}."}
      end
    end
  end
end
