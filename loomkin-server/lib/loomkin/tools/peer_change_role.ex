defmodule Loomkin.Tools.PeerChangeRole do
  @moduledoc "Request a role change for a peer agent (or self)."

  use Jido.Action,
    name: "peer_change_role",
    description:
      "Change the role of an agent on the team. Can target self or a peer agent. " <>
        "Accepts a built-in role name (lead, researcher, coder, reviewer, tester) " <>
        "OR a custom role description (e.g. 'database-migration-specialist focused on Ecto schema changes').",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      target: [type: :string, required: true, doc: "Name of the agent to change (can be self)"],
      new_role: [
        type: :string,
        required: true,
        doc:
          "A built-in role name (lead, researcher, coder, reviewer, tester) " <>
            "OR a description of the specialist role needed " <>
            "(e.g. 'database-migration-specialist focused on Ecto schema changes')"
      ],
      require_approval: [type: :boolean, doc: "If true, request lead approval before changing"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  require Logger

  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Role

  @built_in_names Role.built_in_roles() |> Enum.map(&Atom.to_string/1)

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    target = param!(params, :target)
    new_role_str = param!(params, :new_role)
    require_approval = param(params, :require_approval) || false
    session_id = param(context, :session_id)
    caller_name = param(context, :agent_name)
    caller_role = param(context, :agent_role)

    require_approval =
      if target != caller_name and caller_role != :lead and caller_role != "lead" do
        true
      else
        require_approval
      end

    case resolve_role(new_role_str, session_id) do
      {:built_in, role_atom} ->
        apply_role_change(team_id, target, role_atom, [], require_approval)

      {:generated, %Role{} = role_config} ->
        apply_role_change(
          team_id,
          target,
          role_config.name,
          [role_config: role_config],
          require_approval
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_role(new_role_str, session_id) do
    if new_role_str in @built_in_names do
      {:built_in, String.to_existing_atom(new_role_str)}
    else
      generate_opts = Role.fast_model_opts(session_id)

      case Role.generate(new_role_str, generate_opts) do
        {:ok, role_config} ->
          {:generated, role_config}

        {:error, reason} ->
          Logger.warning(
            "PeerChangeRole: dynamic generation failed (#{inspect(reason)}), trying built-in fallback"
          )

          try_built_in_fallback(new_role_str)
      end
    end
  end

  defp try_built_in_fallback(new_role_str) do
    normalized = new_role_str |> String.downcase() |> String.trim()

    match =
      Enum.find(@built_in_names, fn name ->
        String.contains?(normalized, name)
      end)

    case match do
      nil ->
        {:error, "Could not generate custom role and no built-in role matches '#{new_role_str}'."}

      name ->
        Logger.info("PeerChangeRole: falling back to built-in role #{name}")
        {:built_in, String.to_existing_atom(name)}
    end
  end

  defp apply_role_change(team_id, target, role_name, extra_opts, require_approval) do
    case Manager.find_agent(team_id, target) do
      {:ok, pid} ->
        opts = if require_approval, do: [require_approval: true] ++ extra_opts, else: extra_opts

        case Loomkin.Teams.Agent.change_role(pid, role_name, opts) do
          :ok ->
            {:ok, %{result: "Role of #{target} changed to #{role_name}."}}

          {:error, :unknown_role} ->
            {:error, "Unknown role: #{role_name}"}
        end

      :error ->
        {:error, "Agent #{target} not found in team #{team_id}."}
    end
  end
end
