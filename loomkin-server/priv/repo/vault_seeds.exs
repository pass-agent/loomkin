# Vault seed data — rich interconnected entries for UI testing.
#
# Run with: mix run priv/repo/vault_seeds.exs
# Safe to run multiple times — uses upsert.

alias Loomkin.Vault
alias Loomkin.Vault.Index
alias Loomkin.Repo
alias Loomkin.Schemas.VaultLink

vault_id = "ph-vault"

IO.puts("\n🌙 Seeding vault entries for #{vault_id}...\n")

entries = [
  # ── Projects ──
  %{
    path: "projects/loomkin-cli.md",
    content: """
    ---
    title: Loomkin CLI
    type: project
    tags:
      - cli
      - typescript
      - bun
    status: in-progress
    ---

    # Loomkin CLI

    The primary interface for Loomkin — a terminal-based AI coding tool built with React Ink and Bun.

    ## Architecture

    - **Runtime**: Bun (TypeScript)
    - **UI Framework**: React Ink for terminal rendering
    - **State**: Zustand stores for app, session, and connection state
    - **Transport**: Phoenix channels over WebSocket for real-time agent communication

    ## Key Features

    - Slash commands (`/vault`, `/status`, `/spawn`, `/delegate`)
    - Multi-agent team orchestration from the terminal
    - OAuth device code flow for loomkin.dev authentication
    - Vault knowledge management via `/vault` commands

    See [[specs/slash-command-system]] for the command architecture.
    """
  },
  %{
    path: "projects/loomkin-server.md",
    content: """
    ---
    title: Loomkin Server
    type: project
    tags:
      - elixir
      - phoenix
      - otp
    status: in-progress
    ---

    # Loomkin Server

    The Phoenix/OTP backend that powers agent teams, vault storage, and real-time coordination.

    ## Core Systems

    - **Agent Teams**: GenServer-based agents with role configs, priority routing, and negotiation
    - **Vault**: PostgreSQL-backed knowledge base with full-text search and wiki linking
    - **Decision Graph**: Confidence-propagating DAG for tracking design evolution
    - **Device Auth**: RFC 8628 device code flow for CLI authentication

    ## Key Decisions

    - [[decisions/DR-2026-001-postgres-vault-storage]] — chose Postgres over file storage
    - [[decisions/DR-2026-002-device-code-oauth]] — chose device code over auth code flow

    The server runs on Fly.io with a Postgres database.
    """
  },
  %{
    path: "projects/loomkin-dev.md",
    content: """
    ---
    title: loomkin.dev
    type: project
    tags:
      - web
      - phoenix
      - liveview
    status: planned
    ---

    # loomkin.dev

    The web companion for Loomkin. Handles vault creation, user accounts, team sharing, and the device code verification page.

    ## Planned Features

    - Vault browser (LiveView, same UI as local)
    - User registration and OAuth provider
    - Organization management and invitations
    - Device code verification page at `/device`
    - Vault entry reading and search

    Not a replacement for the CLI — the CLI is the primary coding interface. loomkin.dev is for vault management, sharing, and collaboration.
    """
  },

  # ── People ──
  %{
    path: "people/brandon.md",
    content: """
    ---
    title: Brandon
    type: person
    role: founder
    tags:
      - leadership
      - architecture
    ---

    # Brandon

    Founder and primary architect. Drives product vision, makes architecture decisions, and works directly in the codebase daily.

    ## Focus Areas

    - Product direction and feature prioritization
    - System architecture and technical decisions
    - Elixir/Phoenix backend development
    - AI agent orchestration design
    """
  },
  %{
    path: "people/concierge.md",
    content: """
    ---
    title: Concierge Agent
    type: person
    role: ai-agent
    tags:
      - agent
      - orchestration
    ---

    # Concierge

    The user-facing orchestrator agent. First point of contact for all user requests. Routes tasks to appropriate specialist agents or teams.

    ## Responsibilities

    - Interpret user intent and break down into tasks
    - Spawn specialist teams when needed
    - Report progress and ask clarifying questions
    - Manage the session lifecycle

    Works alongside [[people/orienter]] during bootstrap.
    """
  },
  %{
    path: "people/orienter.md",
    content: """
    ---
    title: Orienter Agent
    type: person
    role: ai-agent
    tags:
      - agent
      - context
    ---

    # Orienter

    The context-gathering agent that runs during session bootstrap. Builds the initial understanding of the project before handing off to the Concierge.

    ## Responsibilities

    - Scan project structure and conventions
    - Read CLAUDE.md and project documentation
    - Identify recent git activity and open work
    - Brief the [[people/concierge]] with project context
    """
  },

  # ── Decisions ──
  %{
    path: "decisions/DR-2026-001-postgres-vault-storage.md",
    content: """
    ---
    title: Postgres-Only Vault Storage
    type: decision
    id: DR-2026-001
    date: "2026-04-02"
    status: accepted
    tags:
      - architecture
      - vault
      - storage
    ---

    # DR-2026-001: Postgres-Only Vault Storage

    ## Context

    The vault system initially had pluggable storage adapters (local filesystem, S3/Tigris). This added complexity for self-hosters who had to configure object storage.

    ## Decision

    Store all vault entries directly in PostgreSQL. The `vault_entries` table already stores full content (body, metadata, tags). The storage adapter layer was redundant.

    ## Consequences

    - **Positive**: Self-hosters only need Postgres (which they already have)
    - **Positive**: No S3/Tigris configuration required
    - **Positive**: Simpler architecture — one source of truth
    - **Negative**: No file attachments (images, PDFs) without adding object storage later
    - **Neutral**: Full-text search via tsvector already worked on the index
    """
  },
  %{
    path: "decisions/DR-2026-002-device-code-oauth.md",
    content: """
    ---
    title: Device Code OAuth for CLI
    type: decision
    id: DR-2026-002
    date: "2026-04-03"
    status: accepted
    tags:
      - architecture
      - oauth
      - cli
    ---

    # DR-2026-002: Device Code OAuth for CLI Auth

    ## Context

    The CLI needs to authenticate with loomkin.dev. Options considered:
    - Authorization code flow (requires local HTTP server for callback)
    - Paste-back flow (user copies token from browser)
    - Device code flow (RFC 8628)

    ## Decision

    Use the device code flow. User gets a short code, enters it at loomkin.dev/device in their browser, and the CLI polls until approved.

    ## Consequences

    - **Positive**: No local HTTP server needed (avoids port conflicts)
    - **Positive**: Clean UX — just a code to enter
    - **Positive**: Standard RFC with well-defined error handling (slow_down, expired, denied)
    - **Negative**: Requires polling (5s interval), slight delay after approval
    """
  },
  %{
    path: "decisions/DR-2026-003-wip-vault-convention.md",
    content: """
    ---
    title: WIP Path Convention for Vault Entries
    type: decision
    id: DR-2026-003
    date: "2026-04-02"
    status: accepted
    tags:
      - vault
      - workflow
      - git
    ---

    # DR-2026-003: WIP Path Convention

    ## Context

    Agents write vault entries during development. Not all work merges — feature branches may be abandoned. We don't want unmerged work polluting the knowledge base.

    ## Decision

    Entries created on feature branches auto-prefix to `wip/{branch}/`. On merge, the `vault_promote` tool moves them to canonical paths and sets status to `published`.

    ## Consequences

    - **Positive**: Clean separation of work-in-progress from authoritative knowledge
    - **Positive**: Stale branches don't pollute the vault
    - **Positive**: Promotion is explicit — someone has to approve the merge
    - **Negative**: Slightly more complex vault tool (branch detection via git)
    """
  },

  # ── Specs ──
  %{
    path: "specs/slash-command-system.md",
    content: """
    ---
    title: Slash Command System
    type: spec
    id: SPEC-001
    status: implemented
    tags:
      - cli
      - architecture
      - commands
    ---

    # Slash Command System

    ## Overview

    The CLI exposes functionality via slash commands (`/command args`). Commands are TypeScript modules that register with a central registry.

    ## Architecture

    Each command exports a `register()` call with:
    - `name` — the command name (e.g., "vault")
    - `aliases` — short forms (e.g., "v")
    - `description` — shown in `/help`
    - `handler(args, ctx)` — async function that executes the command
    - `getArgCompletions(partial)` — optional tab completion

    ## Command Context

    The `CommandContext` provides:
    - `appStore` / `sessionStore` — Zustand state
    - `addSystemMessage(content)` — display output
    - `sendMessage(content)` — send as user message to agent
    - `exit()` — quit the CLI

    ## Registration

    Commands self-register on import. `app.tsx` imports all command files at startup.

    See [[projects/loomkin-cli]] for the broader CLI architecture.
    """
  },
  %{
    path: "specs/vault-entry-lifecycle.md",
    content: """
    ---
    title: Vault Entry Lifecycle
    type: spec
    id: SPEC-002
    status: draft
    tags:
      - vault
      - workflow
    ---

    # Vault Entry Lifecycle

    ## States

    1. **draft** — created on a feature branch (WIP path)
    2. **published** — promoted after branch merge
    3. **archived** — superseded or outdated

    ## Transitions

    - `draft → published` via `vault_promote` tool after merge
    - `published → archived` via `vault_update_entry` with `status: archived`
    - Direct `published` on main branch (no WIP step)

    ## Frontmatter Requirements

    Each entry type has required frontmatter:
    - `spec`: id, status
    - `milestone`: status, date
    - `decision`: id, date, status
    - `meeting`: date
    - `checkin`: date, author
    - `person`: role

    See [[decisions/DR-2026-003-wip-vault-convention]] for the WIP design rationale.
    """
  },

  # ── Milestones ──
  %{
    path: "milestones/v0-1-vault-launch.md",
    content: """
    ---
    title: "v0.1: Vault Launch"
    type: milestone
    status: in-progress
    date: "2026-04-15"
    tags:
      - release
      - vault
    ---

    # v0.1: Vault Launch

    First public release of the vault system.

    ## Deliverables

    - [x] Vault entry CRUD (create, read, update, delete)
    - [x] Full-text search via PostgreSQL tsvector
    - [x] Wiki linking between entries
    - [x] CLI `/vault` commands (auth, list, attach, search)
    - [x] Device code OAuth flow
    - [x] Vault browser LiveView
    - [ ] loomkin.dev deployment
    - [ ] Vault creation on loomkin.dev
    - [ ] Public documentation

    ## Dependencies

    - [[projects/loomkin-server]] — vault API endpoints
    - [[projects/loomkin-cli]] — `/vault` command
    - [[projects/loomkin-dev]] — web interface for creation + sharing
    """
  },
  %{
    path: "milestones/v0-2-agent-vault-integration.md",
    content: """
    ---
    title: "v0.2: Agent Vault Integration"
    type: milestone
    status: planned
    date: "2026-05-01"
    tags:
      - release
      - agents
      - vault
    ---

    # v0.2: Agent Vault Integration

    Agents automatically read from and write to the vault during their work.

    ## Deliverables

    - [ ] Agents query vault for context during planning
    - [ ] Post-task vault journal entries
    - [ ] WIP → published promotion on merge
    - [ ] Vault-aware system prompts
    - [ ] Spec-led development workflow

    ## Dependencies

    - [[milestones/v0-1-vault-launch]] must be complete
    - [[specs/vault-entry-lifecycle]] defines the state machine
    """
  },

  # ── Ideas ──
  %{
    path: "ideas/vault-graph-visualization.md",
    content: """
    ---
    title: Vault Graph Visualization
    type: idea
    tags:
      - visualization
      - vault
      - ui
    ---

    # Vault Graph Visualization

    Render the vault link graph as an interactive force-directed graph. Nodes are entries, edges are links (wiki_link, parent, related, etc.). Color by type, size by link count.

    Could use D3.js or a LiveView-native approach with SVG. The [[projects/loomkin-server]] already has all the link data in the `vault_links` table.

    Would help users understand the shape of their knowledge base at a glance.
    """
  },
  %{
    path: "ideas/agent-memory-tiers.md",
    content: """
    ---
    title: Agent Memory Tiers
    type: idea
    tags:
      - agents
      - memory
      - architecture
    ---

    # Agent Memory Tiers

    Three-tier memory system for long-running agents:

    1. **Hot** — GenServer state (current conversation, working memory)
    2. **Warm** — ETS tables (session-scoped, fast reads)
    3. **Cold** — Vault entries (persistent across sessions, searchable)

    Agents would automatically offload context to warm/cold storage as conversations grow. On session resume, they'd rehydrate from vault entries tagged with their agent name.

    Related to [[milestones/v0-2-agent-vault-integration]].
    """
  },

  # ── Topics ──
  %{
    path: "topics/beam-advantages.md",
    content: """
    ---
    title: BEAM Advantages for AI Agents
    type: topic
    tags:
      - beam
      - elixir
      - architecture
    ---

    # BEAM Advantages for AI Agents

    The Erlang BEAM VM provides unique advantages for AI agent orchestration:

    ## Process Isolation

    Each agent runs as a GenServer process with its own heap. A crash in one agent doesn't affect others. Supervisors automatically restart failed agents.

    ## Preemptive Scheduling

    The BEAM scheduler preemptively switches between processes. No agent can starve others of CPU time, even during heavy LLM response processing.

    ## Hot Code Reload

    Agent role configs and system prompts can be updated without stopping running agents. This enables live tuning of agent behavior.

    ## Distribution

    Built-in clustering via `libcluster` and distributed Erlang. Agent teams can span multiple nodes transparently.

    ## Message Passing

    Agents communicate via typed messages through PubSub. No shared mutable state, no locks, no race conditions.

    These properties make the BEAM the ideal runtime for [[projects/loomkin-server]].
    """
  },
  %{
    path: "topics/spec-led-development.md",
    content: """
    ---
    title: Spec-Led Development
    type: topic
    tags:
      - methodology
      - specs
      - workflow
    ---

    # Spec-Led Development

    A workflow where agents write specs before implementing features:

    1. **Spec phase**: Agent creates a `spec` vault entry with requirements, acceptance criteria, and design decisions
    2. **Review**: User reviews the spec, approves or requests changes
    3. **Implement**: Agent implements against the approved spec
    4. **Verify**: Agent checks implementation against spec criteria
    5. **Close**: Spec status → `implemented`, linked to the commit

    This gives users visibility into what agents plan to build before any code is written. Prevents wasted effort on misunderstood requirements.

    See [[specs/vault-entry-lifecycle]] for how spec entries flow through statuses.
    """
  },

  # ── Notes ──
  %{
    path: "notes/vault-ui-design-notes.md",
    content: """
    ---
    title: Vault UI Design Notes
    type: note
    tags:
      - design
      - vault
      - ui
    ---

    # Vault UI Design Notes

    The vault interface follows the "Night Library" aesthetic:

    - **Thread accents**: Colored lines that vary by entry type, echoing the loom metaphor
    - **Warm surfaces**: Coffee-noir backgrounds (#161416 → #1e1c1e → #272527)
    - **Catppuccin pastels**: Soft accent colors for types (cyan, amber, emerald, rose, peach, mauve)
    - **Mono metadata**: JetBrains Mono for dates, IDs, paths — distinguishes data from prose
    - **Staggered animations**: Cards and entries fade in with slight delays, feels alive

    The browser uses colored dots instead of SVG icons for type identification. Simpler, more distinctive, scales better.
    """
  },
  %{
    path: "notes/oauth-implementation-log.md",
    content: """
    ---
    title: OAuth Implementation Log
    type: note
    tags:
      - oauth
      - implementation
    date: "2026-04-03"
    author: brandon
    ---

    # OAuth Implementation Log

    Built the full device code flow in one session:

    ## Server Side
    - `device_codes` table with user_code, device_code, status, expiry
    - `DeviceAuth` context with RFC 8628 compliance (slow_down enforcement, expiry)
    - Public API endpoints for code generation and token polling
    - LiveView verification page at `/device` with loom styling

    ## CLI Side
    - Separate `cloud.json` config for loomkin.dev credentials
    - Cloud API client targeting loomkin.dev
    - Device code flow with terminal box-drawing display
    - All `/vault` subcommands rewritten to use cloud auth

    ## Key Decision
    Reused existing session tokens (from `Accounts.generate_user_session_token/1`) instead of creating a new token type. Scope enforcement happens at the controller level.

    Related: [[decisions/DR-2026-002-device-code-oauth]]
    """
  },

  # ── Sources ──
  %{
    path: "sources/rfc-8628-device-code.md",
    content: """
    ---
    title: "RFC 8628: Device Authorization Grant"
    type: source
    tags:
      - reference
      - oauth
      - rfc
    ---

    # RFC 8628: OAuth 2.0 Device Authorization Grant

    Reference for the device code flow implementation.

    ## Key Endpoints

    - `POST /device/code` — client requests a device code
    - `POST /device/token` — client polls for token (with device_code + grant_type)

    ## Error Responses

    - `authorization_pending` — user hasn't acted yet (keep polling)
    - `slow_down` — polling too fast (increase interval by 5s)
    - `expired_token` — device code expired (restart flow)
    - `access_denied` — user denied the request

    ## User Code Format

    The spec recommends 8-character codes from a limited alphabet for easy entry. We use `BCDFGHJKLMNPQRSTVWXYZ2345679` (no ambiguous characters) formatted as `XXXX-XXXX`.

    Implementation: [[decisions/DR-2026-002-device-code-oauth]]
    """
  },

  # ── Checkin ──
  %{
    path: "updates/brandon/2026-04-02.md",
    content: """
    ---
    title: "Checkin: 2026-04-02"
    type: checkin
    date: "2026-04-02"
    author: brandon
    tags:
      - daily
    ---

    # April 2nd Checkin

    ## Done

    - Redesigned homepage tagline and auth pages
    - Added `spec` and `milestone` entry types to vault
    - Built WIP path convention for feature branch entries
    - Built `VaultPromote` tool for post-merge entry promotion
    - Wired vault_id into agent context
    - Created `/vault` CLI command with all subcommands

    ## In Progress

    - OAuth device code flow (server + CLI)
    - Vault browser visual redesign

    ## Blockers

    None. Good velocity day.
    """
  },
  %{
    path: "updates/brandon/2026-04-03.md",
    content: """
    ---
    title: "Checkin: 2026-04-03"
    type: checkin
    date: "2026-04-03"
    author: brandon
    tags:
      - daily
    ---

    # April 3rd Checkin

    ## Done

    - Completed OAuth device code flow (full stack)
    - Vault API endpoints (list, show, search)
    - Device verification LiveView at `/device`
    - Stripped storage adapters — vault is now Postgres-only
    - Deleted all dead file sync / S3 / Obsidian code
    - Vault browser redesign: "The Night Library" aesthetic

    ## Next

    - Seed vault with sample data for UI testing
    - Deploy loomkin.dev
    - Test full OAuth flow end-to-end
    """
  }
]

# ── Write all entries ──

Enum.each(entries, fn %{path: path, content: content} ->
  case Vault.write(vault_id, path, content) do
    {:ok, _entry} ->
      IO.puts("  ✓ #{path}")

    {:error, reason} ->
      IO.puts("  ✗ #{path}: #{inspect(reason)}")
  end
end)

IO.puts("")

# ── Create typed links between entries ──

links = [
  # Project → project relationships
  {"projects/loomkin-cli.md", "projects/loomkin-server.md", :related},
  {"projects/loomkin-dev.md", "projects/loomkin-server.md", :related},
  {"projects/loomkin-dev.md", "projects/loomkin-cli.md", :related},

  # Milestone → project dependencies
  {"milestones/v0-1-vault-launch.md", "projects/loomkin-server.md", :parent},
  {"milestones/v0-1-vault-launch.md", "projects/loomkin-cli.md", :related},
  {"milestones/v0-2-agent-vault-integration.md", "milestones/v0-1-vault-launch.md", :follows_up},

  # Decision → project context
  {"decisions/DR-2026-001-postgres-vault-storage.md", "projects/loomkin-server.md", :parent},
  {"decisions/DR-2026-002-device-code-oauth.md", "projects/loomkin-cli.md", :parent},
  {"decisions/DR-2026-003-wip-vault-convention.md", "projects/loomkin-server.md", :parent},

  # Spec → decision rationale
  {"specs/vault-entry-lifecycle.md", "decisions/DR-2026-003-wip-vault-convention.md", :related},
  {"specs/slash-command-system.md", "projects/loomkin-cli.md", :parent},

  # Idea → milestone
  {"ideas/agent-memory-tiers.md", "milestones/v0-2-agent-vault-integration.md", :related},
  {"ideas/vault-graph-visualization.md", "projects/loomkin-server.md", :related},

  # Topic → project
  {"topics/beam-advantages.md", "projects/loomkin-server.md", :related},
  {"topics/spec-led-development.md", "specs/vault-entry-lifecycle.md", :related},

  # Notes → decisions
  {"notes/oauth-implementation-log.md", "decisions/DR-2026-002-device-code-oauth.md", :related},

  # People → projects
  {"people/brandon.md", "projects/loomkin-server.md", :related},
  {"people/concierge.md", "people/orienter.md", :related},

  # Source → decision
  {"sources/rfc-8628-device-code.md", "decisions/DR-2026-002-device-code-oauth.md", :related}
]

IO.puts("🔗 Creating links...")

Enum.each(links, fn {source, target, link_type} ->
  attrs = %{
    vault_id: vault_id,
    source_path: source,
    target_path: target,
    link_type: link_type
  }

  case %VaultLink{} |> VaultLink.changeset(attrs) |> Repo.insert(on_conflict: :nothing) do
    {:ok, _} -> IO.puts("  ✓ #{source} →[#{link_type}]→ #{target}")
    {:error, _} -> IO.puts("  · #{source} →[#{link_type}]→ #{target} (exists)")
  end
end)

stats = Vault.stats(vault_id)
IO.puts("\n🌙 Vault seeded: #{stats.total_entries} entries, #{map_size(stats.by_type)} types\n")
IO.puts("Type breakdown:")

stats.by_type
|> Enum.sort_by(fn {_type, count} -> -count end)
|> Enum.each(fn {type, count} ->
  IO.puts("  #{String.pad_trailing(type || "untyped", 12)} #{count}")
end)

IO.puts("")
