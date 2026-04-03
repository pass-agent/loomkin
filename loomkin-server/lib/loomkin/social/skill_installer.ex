defmodule Loomkin.Social.SkillInstaller do
  @moduledoc """
  Installs a snippet (type: :skill) to a project's agent skill directories.

  The canonical install location is `.agents/skills/<name>/SKILL.md`. Additional
  agent-specific directories receive a relative symlink pointing at the canonical
  location, falling back to a file copy when symlinks are unavailable.
  """

  alias Loomkin.Schemas.Snippet

  @agent_paths %{
    universal: ".agents/skills",
    claude: ".claude/skills",
    windsurf: ".windsurf/skills",
    cursor: ".cursor/skills"
  }

  @doc """
  Install a skill to project, with optional agent targets.

  Always writes physical files to `.agents/skills/<name>/SKILL.md` (the canonical
  location), then creates relative symlinks for each additional agent directory
  requested. Falls back to a file copy if the symlink call fails.

  ## Options

    - `:agents` — list of agent atoms to install for (default: auto-detected from
      existing config directories, falling back to `[:universal]`).
      Valid values: `:universal`, `:claude`, `:windsurf`, `:cursor`.

  ## Examples

      SkillInstaller.install_to_project(snippet, "/my/project")
      SkillInstaller.install_to_project(snippet, "/my/project", agents: [:universal, :claude])

  """
  def install_to_project(snippet, project_path, opts \\ [])

  def install_to_project(%Snippet{type: :skill} = snippet, project_path, opts) do
    agents = Keyword.get(opts, :agents) || detect_agents(project_path)
    agents = if agents == [], do: [:universal], else: agents

    frontmatter = snippet.content["frontmatter"] || %{}
    body = snippet.content["body"] || ""
    name = frontmatter["name"] || snippet.slug || Snippet.slugify(snippet.title)

    canonical_dir = Path.join([project_path, ".agents/skills", name])
    canonical_path = Path.join(canonical_dir, "SKILL.md")

    with :ok <- File.mkdir_p(canonical_dir),
         :ok <- write_skill_file(canonical_path, frontmatter, body) do
      symlink_results =
        agents
        |> Enum.reject(fn agent -> agent == :universal end)
        |> Enum.map(fn agent -> install_agent_link(agent, name, project_path, canonical_dir) end)

      errors = Enum.filter(symlink_results, &match?({:error, _}, &1))

      if errors == [] do
        {:ok, canonical_path}
      else
        {:ok, canonical_path, errors}
      end
    else
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
      {:write_error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  def install_to_project(%Snippet{type: type}, _project_path, _opts) do
    {:error, {:wrong_type, type}}
  end

  @doc """
  Detect which agent config directories exist in the given project path.

  Returns a list of agent atoms whose parent directories are present.
  """
  def detect_agents(project_path) do
    @agent_paths
    |> Enum.filter(fn {_agent, dir} ->
      project_path |> Path.join(Path.dirname(dir)) |> File.dir?()
    end)
    |> Enum.map(fn {agent, _} -> agent end)
  end

  # --- private ---

  defp write_skill_file(path, frontmatter, body) do
    yaml_lines =
      frontmatter
      |> Enum.map(fn {key, value} -> "#{key}: #{yaml_quote(value)}" end)
      |> Enum.join("\n")

    content = "---\n#{yaml_lines}\n---\n\n#{body}\n"

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:write_error, reason}
    end
  end

  defp yaml_quote(value) when is_binary(value) do
    if String.contains?(value, ["\n", ":", "#", "'", "\"", "{", "}", "[", "]"]) do
      ~s("#{String.replace(value, "\"", "\\\"")}")
    else
      value
    end
  end

  defp yaml_quote(value), do: to_string(value)

  defp install_agent_link(agent, name, project_path, canonical_dir) do
    agent_skills_dir = Path.join(project_path, @agent_paths[agent])
    link_path = Path.join(agent_skills_dir, name)

    with :ok <- File.mkdir_p(agent_skills_dir) do
      relative_target = Path.relative_to(canonical_dir, agent_skills_dir)

      case File.ln_s(relative_target, link_path) do
        :ok ->
          {:ok, link_path}

        {:error, _symlink_reason} ->
          try do
            {:ok, _} = File.cp_r(canonical_dir, link_path)
            {:ok, link_path}
          rescue
            _ -> {:error, {:link_and_copy_failed, agent}}
          end
      end
    else
      {:error, reason} -> {:error, {:mkdir_failed, agent, reason}}
    end
  end
end
