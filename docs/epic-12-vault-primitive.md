# Epic 12: Vault Primitive — Structured Knowledge Base for Agents

## Overview

Add a vault system to Loomkin so agents can manage structured collections of markdown files with YAML frontmatter, backed by S3-compatible storage (Tigris, AWS, MinIO) or local filesystem, with PostgreSQL full-text search.

Vaults are domain-agnostic. They work for:
- **Sci-fi novel manuscripts** — chapters, character sheets, world bible, timeline
- **Codebase documentation** — architecture docs, ADRs, runbooks, onboarding guides
- **Research corpus** — papers, notes, synthesis documents, bibliographies
- **Knowledge bases** — FAQs, procedures, policies, reference materials

Agents interact with vaults through four tools: `vault_read`, `vault_write`, `vault_search`, `vault_list`. No UI changes needed — agents use these tools the same way they use `file_read`/`file_write` for local projects.

## Architecture

```
Agent Tools
  |
  +-- vault_read     ──> Vault.read/2
  +-- vault_write    ──> Vault.write/3  (storage + index)
  +-- vault_search   ──> Vault.search/3 (full-text + filters)
  +-- vault_list     ──> Vault.list/2   (browse by type/path)
  |
  v
Vault Context (lib/loomkin/vault.ex)
  |
  +-- Storage (behaviour)               Index (PostgreSQL)
  |   +-- S3 backend (Tigris/AWS)       +-- Full-text search (tsvector)
  |   +-- Local backend (filesystem)    +-- Frontmatter fields indexed
  |                                     +-- Sync from storage on write
  v
Parser (lib/loomkin/vault/parser.ex)
  +-- YAML frontmatter extraction
  +-- Markdown body parsing
  +-- Round-trip serialization
```

### Key Design Decisions

1. **S3/Tigris as source of truth**: Files are plain markdown. They can be edited outside Loomkin (git, text editor, other tools). PostgreSQL is a read-optimized index that gets rebuilt from storage.

2. **YAML frontmatter for metadata**: Every vault file has structured metadata (title, type, tags) in YAML frontmatter. The body is markdown. Same pattern as Jekyll, Hugo, Obsidian.

3. **Domain-agnostic types**: User-defined types — any string is valid. No hardcoded entity types.

4. **Per-session vault binding**: A session can be bound to one vault. All agents in that session share the vault.

5. **No UI changes**: Vault tools are registered like any other agent tool. The existing workspace UI works as-is.

6. **Local-first for development**: Local filesystem backend is the default. S3 is for production/cloud use.

## Dependencies

**New deps to add to `mix.exs`**:
```elixir
{:ex_aws_s3, "~> 2.5"}        # S3 client (Tigris-compatible)
{:ex_aws, "~> 2.5"}           # AWS SDK base
{:yaml_elixir, "~> 2.11"}     # YAML frontmatter parsing
{:sweet_xml, "~> 0.7"}        # Required by ex_aws
{:configparser_ex, "~> 4.1"}  # INI parsing (for AWS credential files)
```

**Note**: Check if `req` can handle S3 directly (via `req_s3` plugin) before adding `ex_aws`. Prefer fewer dependencies. LoreForge uses `ex_aws_s3` which is battle-tested.

**Already installed**:
- `:ecto_sql` — PostgreSQL (index)
- `:jason` — JSON encoding

---

## 12.1: Vault Core — Schema, Configuration & Entry Struct

**Complexity**: Medium
**Dependencies**: None
**Description**: Define the vault entry struct, Ecto schema for the index, and vault configuration.

**Files to create**:
- `lib/loomkin/vault/entry.ex` — Parsed vault entry struct
- `lib/loomkin/schemas/vault_entry.ex` — Ecto schema for PostgreSQL index
- `lib/loomkin/schemas/vault_config.ex` — Ecto schema for vault metadata
- `priv/repo/migrations/*_create_vault_entries.exs`
- `priv/repo/migrations/*_create_vault_configs.exs`

**Entry struct** (in-memory representation of a parsed vault file):
```elixir
defmodule Loomkin.Vault.Entry do
  @type t :: %__MODULE__{
    path: String.t(),           # "characters/elena-voss.md"
    type: String.t(),           # "character" (from frontmatter or inferred from path)
    title: String.t(),          # "Elena Voss" (from frontmatter)
    tags: [String.t()],         # ["protagonist", "scientist"]
    metadata: map(),            # All frontmatter fields as a map
    body: String.t(),           # Markdown body (after frontmatter)
    raw: String.t(),            # Original raw file content
    checksum: String.t()        # MD5 of raw content (for sync change detection)
  }

  defstruct [:path, :type, :title, :tags, :metadata, :body, :raw, :checksum]
end
```

**Ecto schema** (PostgreSQL index):
```elixir
defmodule Loomkin.Schemas.VaultEntry do
  use Ecto.Schema

  schema "vault_entries" do
    field :vault_id, :string            # Vault identifier (slug)
    field :path, :string                # "characters/elena-voss.md"
    field :type, :string                # "character"
    field :title, :string               # "Elena Voss"
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{} # Full frontmatter as JSONB
    field :body, :string                # Markdown body
    field :checksum, :string            # MD5 for sync
    field :search_vector, Loomkin.Ecto.TSVector  # tsvector for full-text search
    field :byte_size, :integer          # File size in bytes
    timestamps()
  end
end
```

**Migration**:
```elixir
def change do
  create table(:vault_entries) do
    add :vault_id, :string, null: false
    add :path, :string, null: false
    add :type, :string
    add :title, :string
    add :tags, {:array, :string}, default: []
    add :metadata, :map, default: %{}
    add :body, :text
    add :checksum, :string
    add :search_vector, :tsvector
    add :byte_size, :integer
    timestamps()
  end

  create unique_index(:vault_entries, [:vault_id, :path])
  create index(:vault_entries, [:vault_id, :type])
  create index(:vault_entries, [:vault_id, :tags], using: :gin)
  create index(:vault_entries, [:search_vector], using: :gin)

  # Auto-update tsvector on insert/update
  execute """
    CREATE OR REPLACE FUNCTION vault_entries_search_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.tags, ' '), '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.body, '')), 'C');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  """, """
    DROP FUNCTION IF EXISTS vault_entries_search_update();
  """

  execute """
    CREATE TRIGGER vault_entries_search_trigger
    BEFORE INSERT OR UPDATE ON vault_entries
    FOR EACH ROW EXECUTE FUNCTION vault_entries_search_update();
  """, """
    DROP TRIGGER IF EXISTS vault_entries_search_trigger ON vault_entries;
  """
end
```

**Vault config schema**:
```elixir
defmodule Loomkin.Schemas.VaultConfig do
  use Ecto.Schema

  schema "vault_configs" do
    field :slug, :string               # Unique vault identifier
    field :name, :string               # Human-readable name
    field :description, :string
    field :storage_backend, :string, default: "local"  # "s3" | "local"
    field :storage_config, :map, default: %{}           # Bucket, region, prefix, etc.
    field :entry_count, :integer, default: 0
    field :total_bytes, :integer, default: 0
    timestamps()
  end
end
```

**Configuration** (in `.loomkin.toml`):
```toml
[vault]
slug = "my-project-vault"
storage = "local"                     # "s3" or "local" (default: local)

[vault.local]
path = "./vault"                      # Local directory path

[vault.s3]
bucket = "my-loomkin-vault"
region = "auto"                       # Tigris uses "auto"
endpoint = "https://fly.storage.tigris.dev"
access_key_id = "${AWS_ACCESS_KEY_ID}"
secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
prefix = "vault/"                     # Optional key prefix
```

**Acceptance Criteria**:
- [ ] Entry struct can represent any vault file with frontmatter + body
- [ ] Ecto schema matches struct with proper JSONB/tsvector fields
- [ ] Migration creates tables with proper indexes
- [ ] Vault config supports S3 and local filesystem backends
- [ ] TSVector trigger auto-generates search vectors
- [ ] Config loads from `.loomkin.toml`

---

## 12.2: Vault Parser — Markdown + YAML Frontmatter

**Complexity**: Small
**Dependencies**: 12.1
**Description**: Parse markdown files with YAML frontmatter into `Entry` structs. Serialize `Entry` structs back to markdown with frontmatter.

**Files to create**:
- `lib/loomkin/vault/parser.ex`

**Parser API**:
```elixir
defmodule Loomkin.Vault.Parser do
  @doc "Parse raw markdown+frontmatter string into an Entry struct"
  def parse(raw_content, path) :: {:ok, Entry.t()} | {:error, term()}

  @doc "Serialize an Entry struct back to markdown+frontmatter string"
  def serialize(entry) :: String.t()

  @doc "Extract just the frontmatter as a map (without parsing body)"
  def extract_frontmatter(raw_content) :: {:ok, map()} | {:error, term()}

  @doc "Update frontmatter fields while preserving body"
  def update_frontmatter(raw_content, updates) :: String.t()
end
```

**Parsing rules**:
1. Frontmatter is delimited by `---` at the start of the file
2. Frontmatter is parsed as YAML via `YamlElixir`
3. `title` defaults to first `# heading` in body if not in frontmatter
4. `type` defaults to the first path segment if not in frontmatter (e.g., `characters/elena.md` -> `"character"` with trailing `s` stripped)
5. `tags` is always normalized to a list of strings
6. All other frontmatter keys go into `metadata`
7. `checksum` is computed as MD5 of the raw content
8. Body is everything after the closing `---`

**Serialization rules**:
1. Frontmatter fields are written in a stable order: `title`, `type`, `tags`, then alphabetical
2. Empty fields are omitted
3. Body is separated from frontmatter by a blank line
4. Round-trip: `parse(serialize(entry))` should produce the same entry

**Acceptance Criteria**:
- [ ] Parses standard YAML frontmatter + markdown body
- [ ] Handles files without frontmatter (body only)
- [ ] Handles empty files gracefully
- [ ] `type` inference from path works
- [ ] `title` inference from first heading works
- [ ] Round-trip serialization preserves content
- [ ] Unicode content handled correctly
- [ ] Malformed YAML returns `{:error, reason}` not crash

---

## 12.3: Vault Storage — S3/Tigris & Local Filesystem

**Complexity**: Medium
**Dependencies**: 12.1
**Description**: Storage backend for reading/writing vault files. Supports S3-compatible storage (Tigris, AWS S3, MinIO) and local filesystem.

**Files to create**:
- `lib/loomkin/vault/storage.ex` — Storage behaviour + dispatcher
- `lib/loomkin/vault/storage/s3.ex` — S3/Tigris implementation
- `lib/loomkin/vault/storage/local.ex` — Local filesystem implementation

**Storage behaviour**:
```elixir
defmodule Loomkin.Vault.Storage do
  @callback get(vault_slug :: String.t(), path :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback put(vault_slug :: String.t(), path :: String.t(), content :: binary()) :: :ok | {:error, term()}
  @callback delete(vault_slug :: String.t(), path :: String.t()) :: :ok | {:error, term()}
  @callback list(vault_slug :: String.t(), prefix :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback exists?(vault_slug :: String.t(), path :: String.t()) :: boolean()

  def backend do
    case Loomkin.Config.get(:vault, :storage) do
      "s3" -> Loomkin.Vault.Storage.S3
      _ -> Loomkin.Vault.Storage.Local
    end
  end
end
```

**S3 storage key format**: `{prefix}{vault_slug}/{path}`
- Example: `vault/my-novel/chapters/chapter-01.md`

**Local filesystem**: Files stored at `{vault.local.path}/{path}`
- Example: `./vault/chapters/chapter-01.md`

**Acceptance Criteria**:
- [ ] S3 backend reads/writes/lists/deletes vault files on Tigris
- [ ] Local backend reads/writes/lists/deletes files in a directory
- [ ] Backend is configurable via `.loomkin.toml`
- [ ] `list/2` supports prefix filtering (e.g., `"characters/"`)
- [ ] Content-type set to `text/markdown` on S3 uploads
- [ ] Error handling for network failures, permission issues
- [ ] Works with Tigris (Fly's S3-compatible storage)

---

## 12.4: Vault Index — PostgreSQL Full-Text Search

**Complexity**: Medium
**Dependencies**: 12.1, 12.2
**Description**: PostgreSQL-backed index for fast querying, full-text search, and filtering of vault entries.

**Files to create**:
- `lib/loomkin/vault/index.ex` — Query API
- `lib/loomkin/ecto/ts_vector.ex` — Custom Ecto type for tsvector (if not already present)

**Index API**:
```elixir
defmodule Loomkin.Vault.Index do
  @doc "Insert or update an entry in the index"
  def upsert(vault_id, %Entry{} = entry) :: {:ok, %VaultEntry{}} | {:error, changeset}

  @doc "Remove an entry from the index"
  def delete(vault_id, path) :: :ok

  @doc "Full-text search across vault entries"
  def search(vault_id, query, opts \\ []) :: [%VaultEntry{}]
  # opts: [type: "character", tags: ["protagonist"], limit: 20, offset: 0]

  @doc "List entries with optional filtering"
  def list(vault_id, opts \\ []) :: [%VaultEntry{}]
  # opts: [type: "chapter", prefix: "chapters/", tags: ["draft"], order: :title | :updated | :path]

  @doc "Get a single entry by path"
  def get(vault_id, path) :: {:ok, %VaultEntry{}} | {:error, :not_found}

  @doc "Count entries by type"
  def count_by_type(vault_id) :: %{String.t() => integer()}

  @doc "List all unique types in the vault"
  def types(vault_id) :: [String.t()]

  @doc "List all unique tags in the vault"
  def tags(vault_id) :: [String.t()]

  @doc "Delete all entries for a vault (for full re-index)"
  def clear(vault_id) :: :ok
end
```

**Full-text search query**:
```elixir
def search(vault_id, query, opts \\ []) do
  base =
    from(e in VaultEntry,
      where: e.vault_id == ^vault_id,
      where: fragment("? @@ websearch_to_tsquery('english', ?)", e.search_vector, ^query),
      order_by: [desc: fragment("ts_rank(?, websearch_to_tsquery('english', ?))", e.search_vector, ^query)],
      select_merge: %{rank: fragment("ts_rank(?, websearch_to_tsquery('english', ?))", e.search_vector, ^query)}
    )

  base
  |> maybe_filter_type(opts[:type])
  |> maybe_filter_tags(opts[:tags])
  |> maybe_limit(opts[:limit] || 20)
  |> maybe_offset(opts[:offset] || 0)
  |> Repo.all()
end
```

**Acceptance Criteria**:
- [ ] Full-text search returns ranked results with relevance scores
- [ ] Search weights: title (A) > tags (B) > body (C)
- [ ] Filter by type and tags
- [ ] `list/2` supports prefix filtering for browsing directory-like structures
- [ ] `upsert/2` is idempotent (same content = no change)
- [ ] `count_by_type/1` and `types/1` provide vault overview
- [ ] GIN indexes make search performant on large vaults (1000+ entries)

---

## 12.5: Vault Sync — Storage to Index

**Complexity**: Medium
**Dependencies**: 12.2, 12.3, 12.4
**Description**: Synchronize vault files from storage (S3/local) to the PostgreSQL index. Handles initial import, incremental updates, and full rebuild.

**Files to create**:
- `lib/loomkin/vault/sync.ex`

**Sync API**:
```elixir
defmodule Loomkin.Vault.Sync do
  @doc "Full sync: list all files in storage, parse each, upsert index. Delete index entries for files no longer in storage."
  def full_sync(vault_id) :: {:ok, %{created: integer(), updated: integer(), deleted: integer()}} | {:error, term()}

  @doc "Sync a single file (after a write or external change)"
  def sync_entry(vault_id, path) :: {:ok, :created | :updated | :unchanged} | {:error, term()}

  @doc "Remove a single entry from index (after a delete in storage)"
  def remove_entry(vault_id, path) :: :ok

  @doc "Check if index is in sync with storage (compare checksums)"
  def check_sync(vault_id) :: {:ok, %{in_sync: integer(), stale: [String.t()], orphaned: [String.t()]}}
end
```

**Full sync algorithm**:
```
1. List all .md files in storage for vault_id
2. List all entries in index for vault_id
3. For each storage file:
   a. Read content, compute checksum
   b. Compare checksum with index entry
   c. If new or changed: parse with Parser, upsert index
   d. If unchanged: skip
4. For each index entry not in storage:
   a. Delete from index (orphaned)
5. Return counts
```

**Performance considerations**:
- Use `Task.async_stream/3` for parallel S3 reads during full sync (10 concurrent)
- Batch index upserts (50 at a time) to avoid transaction overhead
- Full sync of 1000 files should complete in < 30 seconds

**Acceptance Criteria**:
- [ ] Full sync imports all files from storage to index
- [ ] Incremental sync only updates changed files (checksum comparison)
- [ ] Orphaned index entries are cleaned up
- [ ] Full sync is idempotent
- [ ] `check_sync/1` reports sync status without modifying anything
- [ ] Concurrent sync operations don't corrupt index (database-level conflict handling)

---

## 12.6: Vault Context Module — High-Level API

**Complexity**: Small
**Dependencies**: 12.1-12.5
**Description**: The public-facing context module that ties everything together. This is what agent tools call.

**Files to create**:
- `lib/loomkin/vault.ex` — Public API

**Vault context API**:
```elixir
defmodule Loomkin.Vault do
  @doc "Initialize a new vault with the given configuration"
  def init_vault(slug, name, storage_config) :: {:ok, %VaultConfig{}} | {:error, term()}

  @doc "Get vault configuration"
  def get_vault(slug) :: {:ok, %VaultConfig{}} | {:error, :not_found}

  @doc "List all configured vaults"
  def list_vaults() :: [%VaultConfig{}]

  @doc "Read a vault entry (from storage, parsed)"
  def read(vault_slug, path) :: {:ok, Entry.t()} | {:error, :not_found | term()}

  @doc "Write a vault entry (to storage + index)"
  def write(vault_slug, path, content) :: {:ok, Entry.t()} | {:error, term()}

  @doc "Write with structured input (builds frontmatter + body)"
  def write_entry(vault_slug, path, %{title: _, type: _, tags: _, body: _} = attrs) :: {:ok, Entry.t()} | {:error, term()}

  @doc "Delete a vault entry (from storage + index)"
  def delete(vault_slug, path) :: :ok | {:error, term()}

  @doc "Search vault entries (full-text + filters)"
  def search(vault_slug, query, opts \\ []) :: [Entry.t()]

  @doc "List vault entries with optional filtering"
  def list(vault_slug, opts \\ []) :: [Entry.t()]

  @doc "Get vault statistics"
  def stats(vault_slug) :: %{entry_count: integer(), types: map(), total_bytes: integer()}

  @doc "Sync vault storage to index"
  def sync(vault_slug) :: {:ok, sync_report} | {:error, term()}

  @doc "Bind a vault to a session"
  def bind_to_session(vault_slug, session_id) :: :ok | {:error, term()}

  @doc "Get the vault bound to a session"
  def vault_for_session(session_id) :: {:ok, String.t()} | {:error, :no_vault}
end
```

**Write flow**:
```
Vault.write("my-vault", "characters/elena.md", raw_markdown)
  |
  1. Storage.put("my-vault", "characters/elena.md", raw_markdown)
  2. Parser.parse(raw_markdown, "characters/elena.md")
  3. Index.upsert("my-vault", entry)
  4. {:ok, entry}
```

**Session binding**: When a session is bound to a vault, all agents in that session's team can use vault tools. The binding is stored in the session's metadata.

**Acceptance Criteria**:
- [ ] `read/2` returns parsed Entry with frontmatter + body
- [ ] `write/3` persists to both storage and index
- [ ] `write_entry/3` builds proper frontmatter from structured attrs
- [ ] `search/3` returns ranked, filtered results
- [ ] `list/2` supports browsing by type and prefix
- [ ] `stats/1` returns vault overview
- [ ] `sync/1` rebuilds index from storage
- [ ] Session-vault binding works across all agents in a team

---

## 12.7: Agent Tools — vault_read, vault_write, vault_search, vault_list

**Complexity**: Medium
**Dependencies**: 12.6
**Description**: Four Jido.Action-based tools that agents use to interact with vaults. These follow the same pattern as existing tools (FileRead, FileWrite, etc.).

**Files to create**:
- `lib/loomkin/tools/vault_read.ex`
- `lib/loomkin/tools/vault_write.ex`
- `lib/loomkin/tools/vault_search.ex`
- `lib/loomkin/tools/vault_list.ex`

**Files to modify**:
- `lib/loomkin/tools/registry.ex` — Register vault tools in `@solo_tools`

### vault_read

```elixir
defmodule Loomkin.Tools.VaultRead do
  use Jido.Action,
    name: "vault_read",
    description: "Read a file from the project's knowledge vault. Returns the full content including YAML frontmatter metadata and markdown body.",
    schema: [
      path: [type: :string, required: true, doc: "Path within the vault (e.g., 'characters/elena-voss.md')"]
    ]

  def run(params, context) do
    vault_slug = resolve_vault(context)
    case Loomkin.Vault.read(vault_slug, params.path) do
      {:ok, entry} ->
        {:ok, format_entry(entry)}
      {:error, :not_found} ->
        {:error, "Vault entry not found: #{params.path}. Use vault_search or vault_list to find entries."}
    end
  end
end
```

### vault_write

```elixir
defmodule Loomkin.Tools.VaultWrite do
  use Jido.Action,
    name: "vault_write",
    description: "Create or update a file in the project's knowledge vault. Content should be markdown with YAML frontmatter. The frontmatter must include at least a 'title' field. The 'type' is inferred from the path if not specified.",
    schema: [
      path: [type: :string, required: true, doc: "Path within the vault (e.g., 'chapters/chapter-01.md')"],
      content: [type: :string, required: true, doc: "Full file content with YAML frontmatter and markdown body"]
    ]

  def run(params, context) do
    vault_slug = resolve_vault(context)
    case Loomkin.Vault.write(vault_slug, params.path, params.content) do
      {:ok, entry} ->
        {:ok, "Written to vault: #{params.path} (#{entry.type}: #{entry.title})"}
      {:error, reason} ->
        {:error, "Failed to write vault entry: #{inspect(reason)}"}
    end
  end
end
```

### vault_search

```elixir
defmodule Loomkin.Tools.VaultSearch do
  use Jido.Action,
    name: "vault_search",
    description: "Search the project's knowledge vault using full-text search. Returns entries ranked by relevance. Supports filtering by type and tags.",
    schema: [
      query: [type: :string, required: true, doc: "Search query (natural language or keywords)"],
      type: [type: :string, doc: "Filter by entry type (e.g., 'character', 'chapter', 'note')"],
      tags: [type: {:list, :string}, doc: "Filter by tags (entries must have ALL specified tags)"],
      limit: [type: :integer, doc: "Maximum number of results (default: 10)"]
    ]

  def run(params, context) do
    vault_slug = resolve_vault(context)
    opts =
      []
      |> maybe_add(:type, params[:type])
      |> maybe_add(:tags, params[:tags])
      |> Keyword.put(:limit, params[:limit] || 10)

    results = Loomkin.Vault.search(vault_slug, params.query, opts)
    {:ok, format_search_results(results)}
  end
end
```

### vault_list

```elixir
defmodule Loomkin.Tools.VaultList do
  use Jido.Action,
    name: "vault_list",
    description: "List entries in the project's knowledge vault. Browse by type or path prefix. Returns entry paths, titles, and types.",
    schema: [
      type: [type: :string, doc: "Filter by entry type (e.g., 'character', 'chapter')"],
      prefix: [type: :string, doc: "Filter by path prefix (e.g., 'chapters/' to list all chapters)"],
      limit: [type: :integer, doc: "Maximum number of results (default: 50)"]
    ]

  def run(params, context) do
    vault_slug = resolve_vault(context)
    opts =
      []
      |> maybe_add(:type, params[:type])
      |> maybe_add(:prefix, params[:prefix])
      |> Keyword.put(:limit, params[:limit] || 50)

    entries = Loomkin.Vault.list(vault_slug, opts)
    {:ok, format_list_results(entries)}
  end
end
```

### Vault resolution

Each tool resolves the vault from the session context:
```elixir
defp resolve_vault(context) do
  session_id = context[:session_id] || context[:team_id]
  case Loomkin.Vault.vault_for_session(session_id) do
    {:ok, slug} -> slug
    {:error, :no_vault} -> raise "No vault bound to this session."
  end
end
```

**Acceptance Criteria**:
- [ ] `vault_read` returns formatted entry with frontmatter and body
- [ ] `vault_write` creates/updates entries in storage and index
- [ ] `vault_search` returns ranked results with relevance scores
- [ ] `vault_list` supports type and prefix filtering
- [ ] All tools resolve vault from session context
- [ ] Tools are registered in the registry and available to all agents
- [ ] Error messages guide agents to use the right tool
- [ ] Agents can use vault tools when a vault is bound to the session

---

## 12.8: Testing

**Complexity**: Medium
**Dependencies**: 12.1-12.7
**Description**: Comprehensive test suite for the vault system.

**Files to create**:
- `test/loomkin/vault/parser_test.exs`
- `test/loomkin/vault/storage/local_test.exs`
- `test/loomkin/vault/storage/s3_test.exs` (with mock)
- `test/loomkin/vault/index_test.exs`
- `test/loomkin/vault/sync_test.exs`
- `test/loomkin/vault_test.exs` (integration)
- `test/loomkin/tools/vault_read_test.exs`
- `test/loomkin/tools/vault_write_test.exs`
- `test/loomkin/tools/vault_search_test.exs`
- `test/loomkin/tools/vault_list_test.exs`

**Testing strategy**:

- **Parser tests**: Round-trip parsing, edge cases (no frontmatter, empty body, malformed YAML, unicode, nested YAML)
- **Local storage tests**: Real filesystem operations in `tmp/` directory
- **S3 storage tests**: Mock S3 calls with Mox (define `Loomkin.Vault.Storage.Mock` implementing the behaviour)
- **Index tests**: Real PostgreSQL with Ecto sandbox (no mocks). Test full-text search ranking, filtering, upsert idempotency
- **Sync tests**: Use local storage backend + real database. Import files, verify index, modify files, re-sync, verify updates
- **Tool tests**: Verify tool schema, run with mock vault context, verify formatted output
- **Integration test**: Create vault -> write entries -> search -> read -> sync -> verify (end-to-end)

**Test fixtures** (`test/fixtures/vault/`):
```
test/fixtures/vault/
  ├── chapters/
  │   ├── chapter-01.md        # Entry with tags
  │   └── chapter-02.md        # Entry referencing others
  ├── notes/
  │   └── research-notes.md    # Freeform notes
  ├── no-frontmatter.md        # Body only, no YAML
  ├── empty.md                 # Empty file
  └── malformed-yaml.md        # Invalid frontmatter
```

**Acceptance Criteria**:
- [ ] Parser handles all edge cases (empty, no frontmatter, malformed YAML)
- [ ] Full-text search returns correctly ranked results
- [ ] Sync correctly handles create/update/delete scenarios
- [ ] Tools work within agent context
- [ ] At least 90% code coverage on vault modules

---

## Implementation Order

```
12.1 Core Schema/Config ──> 12.2 Parser ──┐
                                           ├──> 12.5 Sync ──> 12.6 Context ──> 12.7 Tools
12.3 Storage ─────────────────────────────┘                                       |
                                                                                  v
12.4 Index ───────────────────────────────────────────────────────────────────> 12.8 Testing
```

**Recommended order**:
1. **12.1** Core schema + config (foundation)
2. **12.2** Parser (needed by everything that reads/writes entries)
3. **12.3** Storage backends (S3 + local)
4. **12.4** Index (PostgreSQL full-text search)
5. **12.5** Sync (ties storage + parser + index together)
6. **12.6** Context module (public API)
7. **12.7** Agent tools (the primary consumer — this is the deliverable)
8. **12.8** Testing (throughout, but final coverage pass here)

**Phase gate**: After 12.6, the vault system is usable by agents. 12.7 (tools) can be demoed with a local storage backend. This is a good milestone for validation.

## Risks & Open Questions

1. **S3 dependency**: Adding `ex_aws_s3` is a significant new dependency. Alternatively, `Req` might handle S3 directly via signed requests. LoreForge uses `ex_aws_s3` successfully, so it's proven.

2. **Eventual consistency**: S3 is eventually consistent for overwrites. Mitigation: always return the written content from `write/3` (don't re-read from S3). The index is the fast-path for reads.

3. **Large vaults**: Full sync of 10,000+ files could be slow. Consider incremental sync via last-modified tracking.

4. **Conflict resolution**: If two agents write to the same vault entry simultaneously, last-write-wins (S3 semantics). For more sophisticated conflict handling, consider adding optimistic locking via checksums.

5. **Local development story**: Local filesystem backend is the default. S3 is the production upgrade path.
