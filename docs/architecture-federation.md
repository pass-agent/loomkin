# Loomkin Federation Architecture

## Vision

Loomkin embraces AT Protocol's federation model: each user runs a Personal Data Server
(PDS) — their local Loomkin instance — that authenticates with a relay (loomkin.dev).
Agents always run locally. The relay coordinates social features, presence, and
collaboration. Files never leave the user's machine.

---

## Architecture Overview

```
                        AT Protocol Layer
          Identity: did:web    Schemas: dev.loomkin.*    AT URIs
    ──────────────────────────────────────────────────────────────

    Your PDS (daemon)          loomkin.dev (Relay)         Friend PDS (daemon)
    ┌────────────────┐        ┌──────────────────┐        ┌────────────────┐
    │ Local Loomkin   │◄──ws──►│ Phoenix Relay     │◄──ws──►│ Local Loomkin   │
    │                 │        │                   │        │                 │
    │ Agent Runtime   │        │ Firehose          │        │ Agent Runtime   │
    │ File Access     │        │ Auth / Identity   │        │ File Access     │
    │ Tool Execution  │        │ Social AppView    │        │ Tool Execution  │
    │ LLM Calls       │        │ Presence          │        │ LLM Calls       │
    │ Signing Key     │        │ Snippet Store     │        │ Signing Key     │
    │ Data Repo       │        │ Workspace Perms   │        │ Data Repo       │
    └────────────────┘        └──────────────────┘        └────────────────┘
                                       ▲
    Mobile (control plane)             │
    ┌────────────────┐                 │
    │ loomkin.dev     │◄───────────────┘
    │ (browser)       │
    │ Status/monitor  │
    │ Approve actions │
    │ Browse/share    │
    └────────────────┘
```

---

## Layer 1: Identity (AT Protocol)

Each Loomkin instance has a decentralized identity:

```
brandon.loomkin.dev  →  did:web:loomkin.dev:brandon  →  DID Document {
  "id": "did:web:loomkin.dev:brandon",
  "verificationMethod": [{
    "type": "Ed25519VerificationKey2020",
    "publicKeyMultibase": "z6Mk..."
  }],
  "service": [{
    "type": "LoomkinPDS",
    "serviceEndpoint": "wss://brandon-mac.local:4000"
  }]
}
```

- `did:web` — trivial to implement: JSON document at `/.well-known/did.json`
- Handle resolution via DNS TXT (`_atproto.brandon.loomkin.dev`) or HTTPS well-known
- Signing key lives on user's machine, signs all records the PDS produces
- Account portable: change PDS hosts, keep DID, keep social graph
- Self-hosters use `did:web:yourdomain.com`, hosted users get `did:web:loomkin.dev:username`

### Record Types (Lexicon-inspired)

```
dev.loomkin.skill       — shareable skill definitions
dev.loomkin.agent       — kin agent configurations
dev.loomkin.session     — session snapshots / chat logs
dev.loomkin.decision    — decision graph nodes
dev.loomkin.solution    — verified solutions (from Pass fingerprinting)
```

Records are addressed via AT URIs:
```
at://brandon.loomkin.dev/dev.loomkin.skill/debug-detective
at://brandon.loomkin.dev/dev.loomkin.session/oauth-refactor-2026-03-21
```

Records are self-authenticating: signed by the user's Ed25519 key, verifiable by anyone.

---

## Layer 2: Auth (Macaroons + Phoenix.Token)

Two token systems for two trust boundaries:

### Internal (BEAM cluster): Phoenix.Token

For agents spawned by Loomkin itself — zero serialization overhead, full process
transparency via existing Horde/Distributed infrastructure.

```elixir
# Issue encrypted token for internal daemon
Phoenix.Token.encrypt(LoomkinWeb.Endpoint, "daemon_v1", %{
  daemon_id: daemon_id,
  user_id: user_id,
  workspace_ids: workspace_ids
})
```

- 30-day max_age, 12-hour rotation via GenServer
- Verified on WebSocket connect in DaemonSocket
- No new dependencies

### External (user daemons, friends): Macaroons

Using `superfly/macaroon-elixir` (production-grade, built by Fly.io):

```
Root Macaroon (issued at login)
  └─ + caveat: user=did:web:loomkin.dev:brandon
      └─ + caveat: instance=mac-studio-1
          └─ + caveat: workspace=loom, role=owner
              └─ [daemon holds this]

Friend's Token (attenuated from owner's)
  └─ + caveat: user=did:web:loomkin.dev:brandon
      └─ + caveat: workspace=loom, role=collaborator
          └─ + caveat: expires=2026-03-22T10:00:00Z
              └─ + caveat: paths=[lib/*, test/*]
                  └─ [friend's daemon holds this]
```

Properties:
- Permissions can only narrow, never broaden (HMAC chain guarantee)
- No server-side ACL lookup at runtime — verification is pure crypto
- Caveats: org, workspace, session, role, paths, expiry
- Per-nonce revocation when needed

### Why Both

| Boundary | Token Type | Reason |
|----------|-----------|--------|
| Internal BEAM cluster | Phoenix.Token | Already in deps, direct process access, sub-ms |
| External daemons | Macaroons | Cryptographic scoping, no server trust required |
| AT Protocol OAuth | DPoP-bound tokens | For full federation interop (future) |

---

## Layer 3: Transport (Hybrid)

### Internal: BEAM Distribution

Existing infrastructure — no changes needed:
- `Loomkin.Teams.Distributed` — Horde/local fallback for cross-node supervision
- `Loomkin.Teams.Cluster` — libcluster with DNS and gossip strategies
- `Loomkin.Channels.Bridge` — bridges Signal events to channel adapters
- Direct GenServer.call across nodes, zero serialization

### External: Phoenix Channels (WebSocket)

```elixir
# lib/loomkin_web/daemon_socket.ex
defmodule LoomkinWeb.DaemonSocket do
  use Phoenix.Socket

  channel "workspace:*", LoomkinWeb.WorkspaceChannel
  channel "session:*", LoomkinWeb.SessionChannel
  channel "social:*", LoomkinWeb.SocialChannel

  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_daemon_token(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :claims, claims)}
      {:error, _} ->
        :error
    end
  end

  def id(socket), do: "daemon:#{socket.assigns.claims.daemon_id}"
end
```

Channel joins enforce macaroon caveats:
```elixir
def join("workspace:" <> workspace_id, _params, socket) do
  case Macaroon.verify(socket.assigns.token, workspace: workspace_id) do
    :ok -> {:ok, socket}
    {:error, _} -> {:error, %{reason: "unauthorized"}}
  end
end
```

---

## Layer 4: File Isolation (Git Worktrees)

Each collaborator gets an isolated working directory:

```
~/projects/loom/                  <- owner's working tree
~/projects/loom-alice/            <- alice's worktree (auto-created)
~/projects/loom-bob/              <- bob's worktree (auto-created)
```

### How It Works

1. Owner invites friend → relay sends scoped macaroon
2. Friend accepts → owner's PDS creates worktree:
   `git worktree add ../loom-alice -b alice/collab`
3. Friend's agents get `project_path = ~/projects/loom-alice`
4. `safe_path!/2` (already in `lib/loomkin/tool.ex`) jails file ops to that path
5. Changes merge back via git flow (PRs, merge commits)

### What's Shared vs Isolated

| Shared (git objects) | Per-collaborator (worktree) |
|---------------------|---------------------------|
| Commit history | Working directory |
| Refs (branches, tags) | HEAD |
| Hooks | Index/staging area |
| Config | Untracked files |

### macOS Bonus

APFS clones (`cp -Rc`) provide instant copy-on-write snapshots with near-zero
disk usage — useful for quick isolation without branch management.

---

## Layer 5: PubSub & Presence (Workspace-Scoped)

### Topic Hierarchy

```
workspace:{ws_id}                          — workspace-wide events
workspace:{ws_id}:team:{team_id}           — team events
workspace:{ws_id}:session:{sess_id}        — session-specific
workspace:{ws_id}:presence                 — who's online
social:user:{did}                          — user activity feed
```

### Authorization Wrapper

Phoenix PubSub has no built-in auth. Wrap it:

```elixir
defmodule Loomkin.AuthorizedPubSub do
  def subscribe(%Scope{} = scope, "workspace:" <> ws_id = topic) do
    with :ok <- Bodyguard.permit(Workspaces.Policy, :read, scope, %{id: ws_id}) do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, topic)
    end
  end
end
```

### Presence

Extend existing `LoomkinWeb.Presence` with workspace-scoped topics:

```elixir
def track_workspace_user(pid, workspace_id, user, meta) do
  track(pid, "presence:workspace:#{workspace_id}", to_string(user.id), meta)
end
```

Presence metadata includes:
- Active sessions with agent counts
- Current activity (orchestrating, idle, reviewing)
- Visibility setting (public session vs private)

---

## Layer 6: Relay (loomkin.dev)

The relay is a Phoenix app that:

1. **Authenticates** daemon connections (macaroon verification)
2. **Aggregates** activity into a firehose (all connected PDS events)
3. **Routes** workspace-scoped PubSub between participants
4. **Serves** the social AppView (trending, profiles, explore)
5. **Stores** social data (snippets, favorites, follows, activity)
6. **Tracks** presence via Phoenix.Presence

The relay does NOT:
- Run agents
- Access files
- Make LLM calls
- Store sensitive project data

### Firehose

Every connected PDS pushes activity events to the relay:
- Skill published/updated
- Agent session started/completed
- Decision graph updated
- Solution verified (Pass-style fingerprinting)

The relay aggregates into a unified stream. AppViews consume the firehose
to build different experiences (web dashboard, mobile monitor, feed generators).

### Federation (Future)

Anyone can run a relay. PDS instances can connect to multiple relays.
Discovery via DID Document service endpoints. This is the AT Protocol model —
loomkin.dev is the first relay, not the only one.

---

## Collaboration Flow

```
Brandon                          loomkin.dev                        Alice
   │                                  │                               │
   │ 1. /invite alice to loom         │                               │
   │    attenuate macaroon            │                               │
   │ ────────────────────────────►    │                               │
   │    caveats: workspace=loom       │                               │
   │             role=collaborator    │                               │
   │             expires=24h          │                               │
   │                                  │  2. relay sends invite        │
   │                                  │ ─────────────────────────►    │
   │                                  │                               │
   │                                  │  3. alice accepts              │
   │                                  │    connects with scoped token │
   │                                  │ ◄─────────────────────────    │
   │                                  │                               │
   │  4. brandon's PDS creates        │                               │
   │     git worktree for alice       │                               │
   │     git worktree add             │                               │
   │       ../loom-alice              │                               │
   │       -b alice/collab            │                               │
   │                                  │                               │
   │  5. relay enforces: alice can    │                               │
   │     only join workspace:loom     │                               │
   │     topics (macaroon caveat)     │                               │
   │                                  │                               │
   │  6. alice sees: agent activity,  │  7. alice's agents run on     │
   │     decision graph, comms feed   │     HER machine, on HER       │
   │     (via PubSub through relay)   │     worktree of the repo      │
   │                                  │                               │
   │  8. alice's agents commit to     │                               │
   │     alice/collab branch          │                               │
   │                                  │                               │
   │  9. brandon reviews & merges     │                               │
   │     via git flow or relay PR     │                               │
```

---

## Module Structure

### PDS (local instance additions)

```
lib/loomkin/federation/
├── identity.ex              # DID document generation, Ed25519 key management
├── handle_resolver.ex       # DNS TXT / .well-known DID resolution
├── record.ex                # Self-authenticating signed records
├── data_repo.ex             # User's record repository (skills, agents, sessions)
├── macaroon.ex              # Wraps superfly/macaroon-elixir, Loomkin caveat types
├── pds.ex                   # PDS GenServer — manages relay connection, sync
├── relay_client.ex          # WebSocket client to relay (reconnect, token rotation)
├── collaboration.ex         # Invite flow, worktree lifecycle, scoped access
└── solution_capture.ex      # Auto-capture solutions with Pass-style fingerprinting
```

### Relay (loomkin.dev)

```
lib/loomkin_relay/
├── application.ex           # OTP supervision tree
├── relay_socket.ex          # Phoenix Socket — daemon authentication
├── workspace_channel.ex     # Workspace-scoped PubSub (macaroon-enforced joins)
├── social_channel.ex        # Social activity (follows, favorites, trending)
├── firehose.ex              # Aggregates PDS activity streams
├── app_view.ex              # Social UI: trending, profiles, activity feeds
├── snippet_store.ex         # Shared content (skills, agents, chat logs)
└── feed_generator.ex        # Custom feed algorithms (trending, recommended)
```

---

## New Dependencies

| Package | Purpose | Notes |
|---------|---------|-------|
| `{:macaroon, github: "superfly/macaroon-elixir"}` | Token attenuation | Fly.io's production library |
| `{:bodyguard, "~> 2.4"}` | Policy-based authorization | Fits existing Scope struct |
| `{:ed25519, "~> 1.4"}` | DID signing keys | Already used in Pass |

All three are lightweight. No heavy framework adoption.

---

## What Pass Becomes

Pass's best ideas dissolve into the federation layer:

| Pass Feature | Loomkin Federation Equivalent |
|---|---|
| Problem fingerprinting | Feed Generator — recommends skills/solutions by structural match |
| Trust scoring | Labeler service — scores skills by fork count, verification, reputation |
| Solution sharing | `dev.loomkin.solution` record type in data repo |
| Ed25519 identity | DID signing keys |
| Relay server | loomkin.dev relay |
| Agent reputation | DID-based reputation derived from solution verification outcomes |

---

## Strategic Decision

**Option A: AT Protocol compatible** — Loomkin records show up in the ATmosphere.
Someone on Bluesky could see "brandon published a skill." Use `did:plc`, real
Lexicons, real XRPC. Ambitious but gives ecosystem effects for free.

**Option B: AT Protocol inspired** — Adopt the architecture (PDS/Relay/AppView,
DIDs, signed records) but build a Loomkin-specific protocol. Simpler, faster.
Add AT Protocol compatibility later without rearchitecting.

**Recommendation: Option B now, designed so Option A is possible later.** Use
`did:web`, define Loomkin-specific record schemas, build the relay as a Phoenix
app. The architecture is the same either way — the difference is just whether
you implement the full XRPC/Lexicon spec or a simplified version.

---

## What's NOT Needed

- Full Merkle Search Tree repository format (signed records in Postgres is fine)
- Full XRPC endpoint spec (Phoenix Channels + REST is sufficient)
- Bluesky interop day one (architectural compatibility is enough)
- FUSE / virtual filesystems (git worktrees handle file isolation)
- Container isolation (overkill for 2-5 collaborators)
- JWT / Joken (Phoenix.Token + macaroons cover both boundaries)

---

## Research Sources

### Daemon Authentication
- Tailscale: machine key + node key + coordination server (curve25519, NaCl crypto_box)
- Fly.io: macaroon attenuation (HMAC chain, org→app→machine caveats)
- Teleport/Smallstep: short-lived certificates with provisioner-based auth
- Happy Coder: OAuth PKCE daemon auth with E2E encrypted messaging

### File Isolation
- Git worktrees: branch-per-collaborator, shared object database, programmatic creation
- AgentFS (Turso): per-process FUSE with copy-on-write overlay (SQLite-backed)
- VS Code Live Share: proxied file access, no real filesystem access for guests
- OverlayFS: copy-on-write layers (Linux only; macOS uses APFS clones)

### Elixir Messaging
- Phoenix Channels: token-authenticated WebSocket with per-channel join authorization
- Phoenix.Presence: CRDT-based, workspace-scoped topic tracking
- PubSub: no built-in auth — wrap with Bodyguard policy checks
- Hybrid: BEAM distribution internal + WebSocket relay external

### AT Protocol
- Federation: PDS → Relay (firehose) → AppView architecture
- Identity: DIDs (did:web, did:plc), handle resolution via DNS/HTTPS
- Auth: OAuth with DPoP, PAR, scoped permissions
- Data: signed repositories, self-authenticating records, AT URIs
- Extensibility: Lexicon schemas, Feed Generators, Labelers
