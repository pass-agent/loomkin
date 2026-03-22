defmodule Loomkin.Teams.Templates do
  @moduledoc """
  Persistent team templates — save and load team configurations from `.loomkin.toml`.

  Templates are stored under `[teams.templates.*]` sections in the TOML config.
  Each template defines a list of agents with name, role, optional model, and optional count.
  """

  alias Loomkin.Teams.Manager

  defstruct [:name, :agents]

  @type agent_config :: %{
          name: String.t(),
          role: atom(),
          model: String.t() | nil,
          count: pos_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          agents: [agent_config()]
        }

  @doc """
  List all templates from the loaded config.

  Reads `[teams.templates.*]` sections from Loomkin.Config.
  """
  @spec list_templates() :: [t()]
  def list_templates do
    case Loomkin.Config.get(:teams) do
      %{templates: templates} when is_map(templates) ->
        Enum.map(templates, fn {name, config} ->
          parse_template(to_string(name), config)
        end)

      _ ->
        []
    end
  end

  @doc """
  Get a specific template by name.

  Returns `{:ok, template}` or `{:error, :not_found}`.
  """
  @spec get_template(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_template(name) do
    case Loomkin.Config.get(:teams) do
      %{templates: templates} when is_map(templates) ->
        atom_name = safe_to_atom(name)

        template_config =
          Map.get(templates, atom_name) || Map.get(templates, name)

        if template_config do
          {:ok, parse_template(name, template_config)}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Spawn a team from a template.

  Creates the team and spawns all agents defined in the template.
  Agent names with `count > 1` get a numeric suffix (e.g., "coder-1", "coder-2").

  ## Options
    * `:project_path` - path to project (optional)
    * `:model` - override model for all agents (optional)

  Returns `{:ok, team_id, agents}` or `{:error, reason}`.
  """
  @spec spawn_from_template(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, atom() | String.t()}
  def spawn_from_template(team_name, template_name, opts \\ []) do
    case get_template(template_name) do
      {:ok, template} ->
        {:ok, team_id} = Manager.create_team(name: team_name, project_path: opts[:project_path])

        agents = expand_agents(template.agents)

        results =
          Enum.map(agents, fn agent_config ->
            role = agent_config.role
            name = agent_config.name
            model = opts[:model] || agent_config[:model]

            spawn_opts =
              [project_path: opts[:project_path]]
              |> then(fn o -> if model, do: Keyword.put(o, :model, model), else: o end)

            case Manager.spawn_agent(team_id, name, role, spawn_opts) do
              {:ok, pid} -> %{name: name, role: role, pid: pid, status: :ok}
              {:error, reason} -> %{name: name, role: role, pid: nil, status: {:error, reason}}
            end
          end)

        {:ok, team_id, results}

      {:error, :not_found} ->
        {:error, :template_not_found}
    end
  end

  @doc """
  Generate a TOML string for a template definition.

  This can be appended to `.loomkin.toml` to persist the template.
  """
  @spec save_template(String.t(), [map()]) :: {:ok, String.t()}
  def save_template(name, agents_config) do
    template = parse_template(name, %{"agents" => agents_config})

    toml_lines = ["[teams.templates.#{name}]", "" | format_agents_toml(template.agents)]
    {:ok, Enum.join(toml_lines, "\n")}
  end

  # --- Private ---

  defp parse_template(name, config) do
    agents_raw =
      Map.get(config, :agents) || Map.get(config, "agents") || []

    agents =
      Enum.map(agents_raw, fn agent ->
        %{
          name: get_val(agent, :name, "agent"),
          role: get_val(agent, :role, "coder") |> to_role_atom(),
          model: get_val(agent, :model, nil),
          count: get_val(agent, :count, 1) |> to_integer()
        }
      end)

    %__MODULE__{name: name, agents: agents}
  end

  defp expand_agents(agents) do
    Enum.flat_map(agents, fn agent ->
      if agent.count <= 1 do
        [agent]
      else
        Enum.map(1..agent.count, fn i ->
          %{agent | name: "#{agent.name}-#{i}", count: 1}
        end)
      end
    end)
  end

  defp get_val(map, key, default) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp to_role_atom(role) when is_atom(role), do: role

  defp to_role_atom(role) when is_binary(role) do
    try do
      String.to_existing_atom(role)
    rescue
      ArgumentError -> :custom
    end
  end

  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(n) when is_binary(n), do: String.to_integer(n)
  defp to_integer(_), do: 1

  defp safe_to_atom(name) when is_atom(name), do: name

  defp safe_to_atom(name) when is_binary(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> name
    end
  end

  defp format_agents_toml(agents) do
    Enum.flat_map(agents, fn agent ->
      lines = ["{name = \"#{agent.name}\", role = \"#{agent.role}\""]

      lines =
        if agent.model,
          do: [hd(lines) <> ", model = \"#{agent.model}\"" | tl(lines)],
          else: lines

      lines =
        if agent.count > 1,
          do: [hd(lines) <> ", count = #{agent.count}" | tl(lines)],
          else: lines

      [hd(lines) <> "}"]
    end)
    |> then(fn entries ->
      ["agents = [", Enum.map_join(entries, ",\n  ", & &1), "]"]
    end)
  end
end
