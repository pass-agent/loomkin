defmodule Loomkin.Tools.VaultAudit do
  @moduledoc "Agent tool for running quality checks against a vault."

  use Jido.Action,
    name: "vault_audit",
    description:
      "Run quality checks against the vault. Scopes: full, links, temporal, frontmatter, structure. " <>
        "Detects broken links, temporal language in evergreen entries, missing frontmatter, and structural issues.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      scope: [
        type: :string,
        doc: "Audit scope: full (default), links, temporal, frontmatter, structure"
      ],
      fix: [type: :boolean, doc: "Auto-fix safe issues (default: false)"]
    ]

  import Ecto.Query
  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultEntry
  alias Loomkin.Schemas.VaultLink
  alias Loomkin.Vault.Validators.Frontmatter
  alias Loomkin.Vault.Validators.TemporalLanguage

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    scope = param(params, :scope, "full")
    fix = param(params, :fix, false)

    checks =
      case scope do
        "full" -> [:links, :temporal, :frontmatter, :structure]
        "links" -> [:links]
        "temporal" -> [:temporal]
        "frontmatter" -> [:frontmatter]
        "structure" -> [:structure]
        other -> {:error, other}
      end

    case checks do
      {:error, bad_scope} ->
        {:error,
         "Unknown scope: #{bad_scope}. Valid: full, links, temporal, frontmatter, structure"}

      scopes ->
        issues = Enum.flat_map(scopes, &run_check(&1, vault_id))
        issues = if fix, do: apply_fixes(vault_id, issues), else: issues
        {:ok, %{result: format_report(issues)}}
    end
  end

  # --- Check: Links ---

  defp run_check(:links, vault_id) do
    # Broken links: vault_links whose target_path has no matching entry
    broken =
      from(l in VaultLink,
        where: l.vault_id == ^vault_id,
        left_join: e in VaultEntry,
        on: e.vault_id == l.vault_id and e.path == l.target_path,
        where: is_nil(e.id),
        select: %{source: l.source_path, target: l.target_path}
      )
      |> Repo.all()

    broken_issues =
      Enum.map(broken, fn %{source: src, target: tgt} ->
        %{
          severity: :critical,
          category: :links,
          message: "Broken link: #{src} -> #{tgt} (target does not exist)",
          path: src,
          fixable: false
        }
      end)

    # Orphan entries: entries with no inbound links
    all_targets =
      from(l in VaultLink,
        where: l.vault_id == ^vault_id,
        select: l.target_path,
        distinct: true
      )
      |> Repo.all()
      |> MapSet.new()

    orphans =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        select: %{path: e.path, title: e.title}
      )
      |> Repo.all()
      |> Enum.reject(fn e -> MapSet.member?(all_targets, e.path) end)

    orphan_issues =
      Enum.map(orphans, fn e ->
        %{
          severity: :info,
          category: :links,
          message: "Orphan entry: #{e.path} (#{e.title || "untitled"}) — no inbound links",
          path: e.path,
          fixable: false
        }
      end)

    broken_issues ++ orphan_issues
  end

  # --- Check: Temporal Language ---

  defp run_check(:temporal, vault_id) do
    entries =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: not is_nil(e.body),
        select: %{path: e.path, body: e.body, entry_type: e.entry_type}
      )
      |> Repo.all()

    Enum.flat_map(entries, fn entry ->
      case TemporalLanguage.validate(entry) do
        :ok ->
          []

        {:warn, violations} ->
          words = Enum.map_join(violations, ", ", & &1.word)

          [
            %{
              severity: :warning,
              category: :temporal,
              message:
                "Temporal language in evergreen #{entry.entry_type}: #{entry.path} — found: #{words}",
              path: entry.path,
              fixable: false
            }
          ]
      end
    end)
  end

  # --- Check: Frontmatter ---

  defp run_check(:frontmatter, vault_id) do
    entries =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: not is_nil(e.entry_type),
        select: %{path: e.path, entry_type: e.entry_type, metadata: e.metadata}
      )
      |> Repo.all()

    Enum.flat_map(entries, fn entry ->
      case Frontmatter.validate(entry) do
        :ok ->
          []

        {:warn, %{missing_fields: missing}} ->
          [
            %{
              severity: :warning,
              category: :frontmatter,
              message:
                "Missing frontmatter in #{entry.entry_type}: #{entry.path} — missing: #{Enum.join(missing, ", ")}",
              path: entry.path,
              fixable: true,
              fix_data: %{entry_type: entry.entry_type, missing_fields: missing}
            }
          ]
      end
    end)
  end

  # --- Check: Structure ---

  defp run_check(:structure, vault_id) do
    entries =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: not is_nil(e.entry_type),
        select: %{path: e.path, entry_type: e.entry_type}
      )
      |> Repo.all()

    Enum.flat_map(entries, fn entry ->
      dir = entry.path |> Path.dirname() |> Path.basename()
      expected_dir = expected_directory(entry.entry_type)

      if expected_dir && dir != expected_dir && entry.path != dir do
        [
          %{
            severity: :info,
            category: :structure,
            message:
              "Structure mismatch: #{entry.path} (type: #{entry.entry_type}) — expected directory prefix: #{expected_dir}/",
            path: entry.path,
            fixable: false
          }
        ]
      else
        []
      end
    end)
  end

  # --- Auto-fix ---

  defp apply_fixes(vault_id, issues) do
    Enum.map(issues, fn issue ->
      if issue[:fixable] && issue[:fix_data] do
        case apply_single_fix(vault_id, issue) do
          :ok -> Map.put(issue, :fixed, true)
          _ -> issue
        end
      else
        issue
      end
    end)
  end

  defp apply_single_fix(vault_id, %{category: :frontmatter, path: path, fix_data: fix_data}) do
    case Loomkin.Vault.read(vault_id, path) do
      {:ok, entry} ->
        defaults = frontmatter_defaults(fix_data.entry_type, fix_data.missing_fields)
        updated_metadata = Map.merge(defaults, entry.metadata || %{})

        updated_entry = %{entry | metadata: updated_metadata}

        case Loomkin.Vault.write(vault_id, path, updated_entry) do
          {:ok, _} -> :ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp apply_single_fix(_vault_id, _issue), do: :error

  defp frontmatter_defaults(entry_type, missing_fields) do
    Map.new(missing_fields, fn field ->
      {field, default_value(entry_type, field)}
    end)
  end

  defp default_value(_type, "date"), do: Date.to_string(Date.utc_today())
  defp default_value(_type, "status"), do: "draft"
  defp default_value(_type, "author"), do: "unknown"
  defp default_value(_type, "id"), do: "FIXME"
  defp default_value(_type, field), do: "FIXME-#{field}"

  # --- Formatting ---

  defp format_report([]) do
    "Vault audit: all clear. No issues found."
  end

  defp format_report(issues) do
    grouped = Enum.group_by(issues, & &1.severity)

    sections =
      [{:critical, "Critical"}, {:warning, "Warnings"}, {:info, "Info"}]
      |> Enum.flat_map(fn {severity, label} ->
        case Map.get(grouped, severity, []) do
          [] ->
            []

          items ->
            lines = Enum.map_join(items, "\n", &format_issue/1)
            ["## #{label} (#{length(items)})\n#{lines}"]
        end
      end)

    total = length(issues)
    fixed = Enum.count(issues, &(&1[:fixed] == true))
    fix_note = if fixed > 0, do: " (#{fixed} auto-fixed)", else: ""

    "# Vault Audit Report\nTotal issues: #{total}#{fix_note}\n\n#{Enum.join(sections, "\n\n")}"
  end

  defp format_issue(issue) do
    fixed_mark = if issue[:fixed], do: " [FIXED]", else: ""
    "- #{issue.message}#{fixed_mark}"
  end

  defp expected_directory("meeting"), do: "meetings"
  defp expected_directory("decision"), do: "decisions"
  defp expected_directory("checkin"), do: "checkins"
  defp expected_directory("note"), do: "notes"
  defp expected_directory("topic"), do: "topics"
  defp expected_directory("project"), do: "projects"
  defp expected_directory("person"), do: "people"
  defp expected_directory("idea"), do: "ideas"
  defp expected_directory("source"), do: "sources"
  defp expected_directory(_), do: nil
end
