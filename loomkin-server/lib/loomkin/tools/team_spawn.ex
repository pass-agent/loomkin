defmodule Loomkin.Tools.TeamSpawn do
  @moduledoc "Spawn a team with agents."

  @valid_roles Loomkin.Teams.Role.built_in_roles() |> Enum.map(&Atom.to_string/1)

  use Jido.Action,
    name: "team_spawn",
    description:
      "Create a new agent team and spawn agents with specified roles. " <>
        "Standard roles: researcher (read-only exploration), coder (implementation), " <>
        "reviewer (code review), tester (run tests), lead (coordination), " <>
        "concierge (user-facing orchestration). " <>
        "You can also specify custom specialist roles by description (e.g. 'database-migration-specialist'). " <>
        "Provide a roles list with name and role for each agent. " <>
        "If spawn_type is 'research' and roles are omitted, Loomkin will infer a minimal research team. " <>
        "Returns a team status summary with team_id and agent list.",
    schema: [
      team_name: [type: :string, required: true, doc: "Human-readable team name"],
      purpose: [
        type: :string,
        required: true,
        doc:
          "Brief description of what this team will do and why it's being created. Shown to the user in the spawn approval prompt."
      ],
      roles: [
        type: {:list, :map},
        required: false,
        doc:
          "List of %{name, role} maps. role can be a standard role or a custom specialist description"
      ],
      project_path: [type: :string, doc: "Path to the project for agents to work on"],
      spawn_type: [
        type: :string,
        required: false,
        doc:
          "Optional spawn type. Use 'research' for auto-approved research sub-teams (skips human gate, budget check still runs)."
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Role

  @doc false
  def resolve_roles(params, context \\ %{}) when is_map(params) and is_map(context) do
    team_name = param!(params, :team_name)
    purpose = param!(params, :purpose)
    roles = param(params, :roles)
    inferred_research? = research_spawn?(params, context)

    cond do
      is_list(roles) and roles != [] ->
        {:ok, roles}

      inferred_research? ->
        {:ok, inferred_research_roles(team_name, purpose)}

      true ->
        {:error, "team_spawn requires a non-empty roles list unless spawn_type is 'research'"}
    end
  end

  @doc false
  def research_spawn?(params, context \\ %{}) when is_map(params) and is_map(context) do
    spawn_type = normalize_spawn_type(param(params, :spawn_type))
    roles = param(params, :roles)

    cond do
      spawn_type == :research ->
        true

      is_list(roles) and roles != [] ->
        false

      inferred_research_context?(context) ->
        true

      true ->
        false
    end
  end

  @impl true
  def run(params, context) do
    team_name = param!(params, :team_name)
    purpose = param!(params, :purpose)
    project_path = param(params, :project_path) || param(context, :project_path)
    parent_team_id = param(context, :parent_team_id)
    session_id = param(context, :session_id)
    model = param(context, :model)
    vault_id = param(context, :vault_id)
    agent_name = param(context, :agent_name) || "architect"

    with {:ok, roles} <- resolve_roles(params, context) do
      spawn_from_roles(
        team_name,
        purpose,
        roles,
        project_path,
        parent_team_id,
        session_id,
        model,
        vault_id,
        agent_name
      )
    end
  end

  defp normalize_spawn_type(spawn_type) when spawn_type in [:research, "research"], do: :research
  defp normalize_spawn_type(_spawn_type), do: nil

  defp inferred_research_context?(context) do
    role = param(context, :role)
    role in [:concierge, "concierge", :lead, "lead"]
  end

  defp inferred_research_roles(team_name, purpose) do
    researcher_name =
      case infer_agent_name(team_name) do
        nil -> "researcher-1"
        name -> name
      end

    [
      %{
        name: researcher_name,
        role: "researcher",
        focus: purpose
      }
    ]
  end

  defp infer_agent_name(team_name) when is_binary(team_name) do
    slug =
      team_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "" do
      nil
    else
      "#{slug}-researcher"
    end
  end

  defp infer_agent_name(_), do: nil

  defp spawn_from_roles(
         team_name,
         purpose,
         roles,
         project_path,
         parent_team_id,
         session_id,
         model,
         vault_id,
         agent_name
       ) do
    require Logger

    Logger.info(
      "[Kin:team_spawn] team=#{team_name} roles=#{inspect(roles)} parent=#{inspect(parent_team_id)}"
    )

    team_result =
      if parent_team_id do
        Manager.create_sub_team(parent_team_id, agent_name,
          name: team_name,
          project_path: project_path
        )
      else
        Manager.create_team(name: team_name, project_path: project_path)
      end

    case team_result do
      {:error, reason} ->
        {:error, "Failed to create team '#{team_name}': #{inspect(reason)}"}

      {:ok, team_id} ->
        do_spawn_agents(
          team_id,
          team_name,
          purpose,
          roles,
          project_path,
          session_id,
          model,
          vault_id,
          agent_name,
          parent_team_id
        )
    end
  end

  defp do_spawn_agents(
         team_id,
         team_name,
         purpose,
         roles,
         project_path,
         session_id,
         model,
         vault_id,
         requesting_agent,
         parent_team_id
       ) do
    require Logger

    spawn_opts =
      [project_path: project_path]
      |> then(fn opts -> if session_id, do: [{:session_id, session_id} | opts], else: opts end)
      |> then(fn opts -> if model, do: [{:model, model} | opts], else: opts end)
      |> then(fn opts -> if vault_id, do: [{:vault_id, vault_id} | opts], else: opts end)

    spawn_results =
      Enum.map(roles, fn role_map ->
        name = Map.get(role_map, :name) || Map.get(role_map, "name")
        role = Map.get(role_map, :role) || Map.get(role_map, "role")

        case resolve_role(role) do
          {:built_in, role_atom} ->
            case Manager.spawn_agent(team_id, name, role_atom, spawn_opts) do
              {:ok, _pid} -> {:ok, name, role_atom}
              {:error, reason} -> {:error, name, role_atom, inspect(reason)}
            end

          {:custom, role_desc} ->
            generate_opts = Role.fast_model_opts(session_id)

            case Role.generate(role_desc, generate_opts) do
              {:ok, %Role{} = role_config} ->
                custom_opts = Keyword.put(spawn_opts, :role_config, role_config)

                case Manager.spawn_agent(team_id, name, role_config.name, custom_opts) do
                  {:ok, _pid} -> {:ok, name, role_config.name}
                  {:error, reason} -> {:error, name, role_config.name, inspect(reason)}
                end

              {:error, gen_reason} ->
                Logger.warning(
                  "Role.generate failed for '#{role_desc}': #{inspect(gen_reason)}, falling back"
                )

                fallback = fuzzy_match_role(role_desc) || :researcher

                case Manager.spawn_agent(team_id, name, fallback, spawn_opts) do
                  {:ok, _pid} -> {:ok, name, fallback}
                  {:error, reason} -> {:error, name, fallback, inspect(reason)}
                end
            end
        end
      end)

    # Build and send team manifest to each successfully spawned agent
    successful_agents =
      Enum.flat_map(spawn_results, fn
        {:ok, name, role} -> [%{name: name, role: role}]
        _ -> []
      end)

    Enum.each(successful_agents, fn %{name: spawned_name} ->
      other_agents = Enum.reject(successful_agents, &(&1.name == spawned_name))

      personal_manifest =
        format_personal_manifest(
          spawned_name,
          team_name,
          purpose,
          other_agents,
          requesting_agent,
          parent_team_id
        )

      case Manager.find_agent(team_id, spawned_name) do
        {:ok, pid} -> Agent.add_briefing(pid, personal_manifest)
        _ -> :ok
      end
    end)

    lines =
      Enum.map(spawn_results, fn
        {:ok, name, role} -> "  - #{name} (#{role}): spawned"
        {:error, name, role, reason} -> "  - #{name} (#{role}): failed - #{reason}"
      end)

    summary = """
    Team "#{team_name}" created (id: #{team_id})
    Agents:
    #{Enum.join(lines, "\n")}
    """

    {:ok, %{result: String.trim(summary), team_id: team_id}}
  end

  defp format_personal_manifest(
         my_name,
         team_name,
         purpose,
         teammates,
         requesting_agent,
         parent_team_id
       ) do
    teammate_lines =
      teammates
      |> Enum.map(fn %{name: name, role: role} ->
        comm_hint = communication_hint(role)
        "- **#{name}** (#{role})#{comm_hint}"
      end)
      |> Enum.join("\n")

    requester_section =
      if requesting_agent && parent_team_id do
        """

        **Spawned by:** #{requesting_agent} (in parent team #{parent_team_id}).
        Report your results back to #{requesting_agent} via cross_team_query or peer_complete_task.
        If you need clarification on your task, ask #{requesting_agent} directly.
        """
      else
        ""
      end

    """
    [Team Briefing] You are #{my_name} in team "#{team_name}".
    Purpose: #{purpose}

    Your teammates:
    #{teammate_lines}
    #{requester_section}
    Use peer_message to communicate. Check search_keepers for prior context before starting work.
    """
  end

  defp communication_hint(:lead), do: " — your team lead"
  defp communication_hint(_), do: ""

  # Resolve a role string to either a built-in role atom or a custom role description.
  # Returns {:built_in, atom} for known roles, {:custom, string} for unknown descriptions.
  defp resolve_role(role) when is_atom(role), do: {:built_in, role}

  defp resolve_role(role) when is_binary(role) do
    downcased = String.downcase(role)

    # Exact match first
    if downcased in @valid_roles do
      {:built_in, String.to_existing_atom(downcased)}
    else
      case fuzzy_match_role(role) do
        nil -> {:custom, role}
        atom -> {:built_in, atom}
      end
    end
  end

  defp resolve_role(_), do: {:built_in, :researcher}

  # Keyword-based fuzzy match for descriptive role strings.
  # Returns the best matching built-in role atom, or nil if no match.
  defp fuzzy_match_role(role) when is_binary(role) do
    downcased = String.downcase(role)

    cond do
      String.contains?(downcased, "review") ->
        :reviewer

      String.contains?(downcased, "test") ->
        :tester

      String.contains?(downcased, "code") or String.contains?(downcased, "implement") ->
        :coder

      String.contains?(downcased, "research") or String.contains?(downcased, "analy") or
        String.contains?(downcased, "audit") or String.contains?(downcased, "explor") or
        String.contains?(downcased, "investigat") or String.contains?(downcased, "document") ->
        :researcher

      String.contains?(downcased, "lead") or String.contains?(downcased, "coordinat") ->
        :lead

      String.contains?(downcased, "concierge") or String.contains?(downcased, "host") ->
        :concierge

      # If the LLM sends a security/quality/architecture analysis role, map to researcher
      String.contains?(downcased, "security") or String.contains?(downcased, "quality") or
        String.contains?(downcased, "architect") or String.contains?(downcased, "coverage") ->
        :researcher

      true ->
        nil
    end
  end
end
