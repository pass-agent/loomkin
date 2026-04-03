defmodule Loomkin.Social.SkillImporter do
  @moduledoc """
  Imports skills from local disk or remote git repositories into snippet records.

  Supports all common agent skill directory conventions. When multiple directories
  contain the same skill name, the first directory found wins (see `@skill_directories`
  for scan order).
  """

  require Logger

  alias Loomkin.Social

  @skill_directories [
    ".agents/skills",
    ".claude/skills",
    ".windsurf/skills",
    ".cursor/skills"
  ]

  @doc """
  Import skills from all known skill directories under `project_path`.

  Scans each directory in `@skill_directories` for `<name>/SKILL.md` entries.
  Skills are deduplicated by name — the first directory that contains a given
  skill name takes precedence.

  Returns a list of `{:ok, snippet}` / `{:error, reason}` tuples, one per skill
  found across all directories.
  """
  def import_from_disk(user, project_path) do
    @skill_directories
    |> Enum.flat_map(fn relative_dir ->
      skills_dir = Path.join(project_path, relative_dir)
      scan_skills_dir(skills_dir)
    end)
    |> deduplicate_by_name()
    |> Enum.map(fn {dir_name, skill_path} ->
      case parse_skill_md(skill_path) do
        {:ok, {frontmatter, body}} ->
          Social.create_snippet(user, %{
            title: frontmatter["name"] || dir_name,
            description: frontmatter["description"],
            type: :skill,
            content: %{"frontmatter" => frontmatter, "body" => body},
            visibility: :private
          })

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Import skills from a git repository URL.

  Clones the repo (shallow, depth 1) to a temporary directory, scans for
  `SKILL.md` files using the same logic as `import_from_disk/2`, creates snippet
  records for each found skill, then removes the temp directory.

  Supports repositories following the agentskills.io convention — skill directories
  in `.agents/skills/`, `.claude/skills/`, `.windsurf/skills/`, or `.cursor/skills/`,
  each containing a `SKILL.md` file.

  ## Options

  None currently; reserved for future use (e.g., branch selection).

  ## Return values

    - `{:ok, [snippet]}` — list of created snippets (may be empty if no skills found)
    - `{:error, {:git_clone_failed, exit_code}}` — git not installed or clone failed
    - `{:error, term}` — other unexpected errors

  """
  @valid_git_url ~r{^(https?://|git@)}

  @spec import_from_git(Loomkin.Accounts.User.t(), String.t(), keyword()) ::
          {:ok, [Loomkin.Schemas.Snippet.t()]} | {:error, term()}

  def import_from_git(user, repo_url, _opts \\ []) do
    unless Regex.match?(@valid_git_url, repo_url) do
      {:error, :invalid_repo_url}
    else
      do_import_from_git(user, repo_url)
    end
  end

  defp do_import_from_git(user, repo_url) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "loomkin_skill_import_#{System.unique_integer([:positive])}")

    try do
      case System.cmd("git", ["clone", "--depth", "1", repo_url, tmp_dir], stderr_to_stdout: true) do
        {_output, 0} ->
          results = import_from_disk(user, tmp_dir)

          created =
            Enum.flat_map(results, fn
              {:ok, snippet} ->
                [snippet]

              {:error, reason} ->
                Logger.warning(
                  "SkillImporter: skipping skill due to parse error: #{inspect(reason)}"
                )

                []
            end)

          {:ok, created}

        {_output, exit_code} ->
          {:error, {:git_clone_failed, exit_code}}
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  @doc """
  Parse a `SKILL.md` file at `path`.

  Returns `{:ok, {frontmatter_map, body_string}}` or `{:error, reason}`.
  """
  def parse_skill_md(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse_skill_content(content)}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Parse the raw string content of a `SKILL.md` file.

  Returns `{frontmatter_map, body_string}`. If no valid YAML frontmatter block is
  present, `frontmatter_map` will be `%{}` and the full content is used as the body.
  """
  def parse_skill_content(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [_before, yaml_str, body] ->
        frontmatter =
          case YamlElixir.read_from_string(yaml_str) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        {frontmatter, String.trim(body)}

      _ ->
        {%{}, String.trim(content)}
    end
  end

  # --- private ---

  defp scan_skills_dir(skills_dir) do
    if File.dir?(skills_dir) do
      case File.ls(skills_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
          |> Enum.flat_map(fn dir_name ->
            skill_path = Path.join([skills_dir, dir_name, "SKILL.md"])
            if File.exists?(skill_path), do: [{dir_name, skill_path}], else: []
          end)

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  defp deduplicate_by_name(skills) do
    skills
    |> Enum.reduce({[], MapSet.new()}, fn {name, _path} = entry, {acc, seen} ->
      if MapSet.member?(seen, name) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, name)}
      end
    end)
    |> then(fn {acc, _seen} -> Enum.reverse(acc) end)
  end
end
