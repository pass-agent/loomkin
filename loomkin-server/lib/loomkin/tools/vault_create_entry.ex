defmodule Loomkin.Tools.VaultCreateEntry do
  @moduledoc "Agent tool for creating structured vault entries with automatic path resolution and linking."

  use Jido.Action,
    name: "vault_create_entry",
    description:
      "Create a new vault entry with automatic path resolution, frontmatter, and optional linking. " <>
        "Supports types: note, topic, project, person, decision, meeting, checkin, idea, source, stream_idea, guest_profile. " <>
        "Decisions get auto-incremented DR numbers. Meetings/checkins/decisions require entry_date.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      title: [type: :string, required: true, doc: "Entry title, used for filename"],
      entry_type: [
        type: :string,
        required: true,
        doc:
          "Entry type: note, topic, project, person, decision, meeting, checkin, idea, source, stream_idea, guest_profile"
      ],
      content: [type: :string, required: true, doc: "Markdown body (without frontmatter)"],
      tags: [type: {:list, :string}, doc: "List of tags"],
      parent_path: [type: :string, doc: "Path to parent entry (creates a parent link)"],
      related_paths: [
        type: {:list, :string},
        doc: "List of paths to related entries (creates related links)"
      ],
      extra_frontmatter: [
        type: :string,
        doc: "JSON string of additional frontmatter fields to merge"
      ],
      entry_date: [
        type: :string,
        doc: "YYYY-MM-DD date, required for meeting/checkin/decision types"
      ],
      author: [type: :string, doc: "Author name, required for checkin type"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultConfig
  alias Loomkin.Schemas.VaultLink
  alias Loomkin.Vault
  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.Index

  @date_required_types ~w(meeting checkin decision)

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    title = param!(params, :title)
    entry_type = param!(params, :entry_type)
    content = param!(params, :content)
    tags = param(params, :tags, [])
    parent_path = param(params, :parent_path)
    related_paths = param(params, :related_paths, [])
    extra_fm_json = param(params, :extra_frontmatter)
    entry_date = param(params, :entry_date)
    author = param(params, :author)

    with :ok <- validate_date_required(entry_type, entry_date),
         :ok <- validate_author_required(entry_type, author),
         {:ok, extra_fm} <- parse_extra_frontmatter(extra_fm_json),
         {:ok, path, metadata} <-
           resolve_path_and_metadata(vault_id, entry_type, title, entry_date, author),
         :ok <- check_no_duplicate(vault_id, path),
         entry <-
           build_entry(vault_id, path, title, entry_type, content, tags, metadata, extra_fm),
         {:ok, _written} <- Vault.write_entry(vault_id, entry),
         :ok <- create_links(vault_id, path, parent_path, related_paths) do
      tags_str = if tags == [], do: "", else: "\n  Tags: #{Enum.join(tags, ", ")}"
      links_str = format_links(parent_path, related_paths)

      {:ok,
       %{
         result: "Created #{entry_type}: \"#{title}\"\n  Path: #{path}#{tags_str}#{links_str}"
       }}
    end
  end

  # --- Validation ---

  defp validate_date_required(entry_type, entry_date)
       when entry_type in @date_required_types and (is_nil(entry_date) or entry_date == "") do
    {:error, "entry_date (YYYY-MM-DD) is required for #{entry_type} entries"}
  end

  defp validate_date_required(_type, _date), do: :ok

  defp validate_author_required("checkin", author) when is_nil(author) or author == "" do
    {:error, "author is required for checkin entries"}
  end

  defp validate_author_required(_type, _author), do: :ok

  defp parse_extra_frontmatter(nil), do: {:ok, %{}}
  defp parse_extra_frontmatter(""), do: {:ok, %{}}

  defp parse_extra_frontmatter(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "extra_frontmatter must be a JSON object"}
      {:error, _} -> {:error, "invalid JSON in extra_frontmatter"}
    end
  end

  defp check_no_duplicate(vault_id, path) do
    case Index.get(vault_id, path) do
      nil -> :ok
      _exists -> {:error, "Entry already exists at #{path}. Use vault_update_entry to modify it."}
    end
  end

  # --- Path resolution ---

  defp resolve_path_and_metadata(vault_id, "decision", title, date, _author) do
    case next_dr_number(vault_id, date) do
      {:ok, number, year} ->
        padded = String.pad_leading(Integer.to_string(number), 3, "0")
        path = "decisions/DR-#{year}-#{padded}-#{slugify(title)}.md"
        metadata = %{"dr_number" => number, "date" => date}
        {:ok, path, metadata}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_path_and_metadata(_vault_id, "meeting", title, date, _author) do
    {:ok, "meetings/#{date}-#{slugify(title)}.md", %{"date" => date}}
  end

  defp resolve_path_and_metadata(_vault_id, "checkin", _title, date, author) do
    {:ok, "updates/#{slugify(author)}/#{date}.md", %{"date" => date, "author" => author}}
  end

  defp resolve_path_and_metadata(_vault_id, entry_type, title, _date, _author) do
    dir =
      case entry_type do
        "note" -> "notes"
        "topic" -> "topics"
        "project" -> "projects"
        "person" -> "people"
        "idea" -> "ideas"
        "source" -> "sources"
        "stream_idea" -> "ideas/streams"
        "guest_profile" -> "ideas/streams/guests"
        other -> other
      end

    {:ok, "#{dir}/#{slugify(title)}.md", %{}}
  end

  # --- Entry building ---

  defp build_entry(vault_id, path, title, entry_type, content, tags, metadata, extra_fm) do
    merged_metadata =
      extra_fm
      |> Map.merge(metadata)
      |> Map.put("title", title)
      |> Map.put("type", entry_type)

    merged_metadata =
      if tags != [] do
        Map.put(merged_metadata, "tags", tags)
      else
        merged_metadata
      end

    %Entry{
      vault_id: vault_id,
      path: path,
      title: title,
      entry_type: entry_type,
      body: content,
      metadata: merged_metadata,
      tags: tags || []
    }
  end

  # --- DR number auto-increment ---

  defp next_dr_number(vault_id, date) do
    year = String.slice(date, 0, 4)

    case Vault.get_config(vault_id) do
      {:ok, config} ->
        sequences = get_in(config.metadata, ["dr_sequences"]) || %{}
        current = Map.get(sequences, year, 0)
        next = current + 1

        updated_sequences = Map.put(sequences, year, next)
        updated_metadata = Map.put(config.metadata || %{}, "dr_sequences", updated_sequences)

        config
        |> VaultConfig.changeset(%{metadata: updated_metadata})
        |> Repo.update()

        {:ok, next, year}

      {:error, _} = err ->
        err
    end
  end

  # --- Linking ---

  defp create_links(vault_id, source_path, parent_path, related_paths) do
    links =
      if parent_path do
        [
          %{
            vault_id: vault_id,
            source_path: source_path,
            target_path: parent_path,
            link_type: :parent
          }
        ]
      else
        []
      end

    related =
      Enum.map(related_paths || [], fn target ->
        %{vault_id: vault_id, source_path: source_path, target_path: target, link_type: :related}
      end)

    Enum.each(links ++ related, fn attrs ->
      %VaultLink{}
      |> VaultLink.changeset(attrs)
      |> Repo.insert()
    end)

    :ok
  end

  defp format_links(nil, []), do: ""

  defp format_links(parent_path, related_paths) do
    parts =
      if parent_path do
        ["\n  Links: -> #{parent_path} (parent)"]
      else
        []
      end

    related =
      Enum.map(related_paths || [], fn p -> "\n         -> #{p} (related)" end)

    Enum.join(parts ++ related)
  end

  # --- Helpers ---

  @doc false
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
