defmodule Loomkin.Skills.Resolver do
  @moduledoc """
  Resolves available skills from disk, database, and the Jido registry.
  Returns Jido.AI.Skill.Spec structs for prompt injection.
  """

  import Ecto.Query

  require Logger

  alias Jido.AI.Skill.Registry, as: SkillRegistry
  alias Jido.AI.Skill.Spec
  alias Loomkin.Repo
  alias Loomkin.Schemas.Snippet
  alias Loomkin.Social

  @skill_directories [
    ".agents/skills",
    ".claude/skills",
    ".windsurf/skills",
    ".cursor/skills"
  ]

  @doc """
  Loads skills from all known agent skill directories within `project_path`
  into the Jido registry. Scans `.agents/skills`, `.claude/skills`,
  `.windsurf/skills`, and `.cursor/skills`.

  Returns `{:ok, count}`.
  """
  @spec load_from_disk(String.t()) :: {:ok, non_neg_integer()}
  def load_from_disk(project_path) do
    skill_paths =
      @skill_directories
      |> Enum.map(&Path.join(project_path, &1))
      |> Enum.filter(&File.dir?/1)

    if skill_paths != [] do
      case SkillRegistry.load_from_paths(skill_paths) do
        {:ok, count} ->
          {:ok, count}

        {:error, reason} ->
          Logger.warning("[Skills] Failed to load skills from disk: #{inspect(reason)}")
          {:ok, 0}
      end
    else
      {:ok, 0}
    end
  rescue
    e ->
      Logger.warning("[Skills] Unexpected error loading skills from disk: #{inspect(e)}")
      {:ok, 0}
  end

  @doc """
  Loads skill snippets owned by `user` from the database and converts them
  to `%Spec{}` structs.

  Returns an empty list when `user` is `nil`.
  """
  @spec load_from_db(map() | nil) :: [Spec.t()]
  def load_from_db(nil), do: []

  def load_from_db(user) do
    user
    |> Social.list_user_snippets(type: :skill)
    |> Enum.map(&snippet_to_spec/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns all known skill specs by merging the Jido registry (disk-loaded)
  with DB-sourced specs for the given user.

  DB specs win on name conflicts, enabling user overrides of disk skills.
  """
  @spec list_manifests(String.t() | nil, map() | nil) :: [Spec.t()]
  def list_manifests(_project_path, user) do
    registry_specs = SkillRegistry.all()
    db_specs = load_from_db(user)

    db_names = MapSet.new(db_specs, & &1.name)

    deduped_registry =
      Enum.reject(registry_specs, fn spec -> MapSet.member?(db_names, spec.name) end)

    deduped_registry ++ db_specs
  end

  @doc """
  Retrieves the body text for a skill by name.

  Checks the Jido registry first, then falls back to a DB lookup against
  skill snippets whose frontmatter `name` field matches.

  Returns `{:ok, body_text}` or `{:error, :not_found}`.
  """
  @spec get_body(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_body(skill_name) do
    case SkillRegistry.lookup(skill_name) do
      {:ok, spec} ->
        extract_body(spec.body_ref)

      _ ->
        get_body_from_db(skill_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @valid_skill_name ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  defp snippet_to_spec(snippet) do
    frontmatter = get_in(snippet.content, ["frontmatter"]) || %{}
    body = get_in(snippet.content, ["body"]) || ""

    name =
      Map.get(frontmatter, "name") ||
        Snippet.slugify(snippet.title)

    if not (is_binary(name) and name != "" and Regex.match?(@valid_skill_name, name)) do
      Logger.warning(
        "[Skills] Skipping snippet id=#{snippet.id} — invalid skill name: #{inspect(name)}"
      )

      nil
    else
      description =
        Map.get(frontmatter, "description") ||
          snippet.description ||
          ""

      raw_tools = Map.get(frontmatter, "allowed-tools")

      allowed_tools =
        raw_tools
        |> List.wrap()
        |> Enum.reject(&is_nil/1)

      %Spec{
        name: name,
        description: description,
        body_ref: {:inline, body},
        source: {:file, "db:#{snippet.id}"},
        tags: snippet.tags || [],
        allowed_tools: allowed_tools
      }
    end
  end

  defp extract_body({:inline, text}), do: {:ok, text}
  defp extract_body({:file, path}), do: File.read(path)
  defp extract_body(nil), do: {:error, :not_found}

  defp get_body_from_db(skill_name) do
    result =
      from(s in Snippet,
        where: s.type == :skill,
        where: fragment("?->'frontmatter'->>'name' = ?", s.content, ^skill_name),
        order_by: [desc: s.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case result do
      %Snippet{} = snippet ->
        body = get_in(snippet.content, ["body"]) || ""
        {:ok, body}

      nil ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Skills] Failed to fetch skill body from DB: #{inspect(e)}")
      {:error, :not_found}
  end
end
