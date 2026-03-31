# Epic 20: Federation & Collaboration

## Problem Statement

Loomkin has a production-grade auth system (Epic 17.1) and a complete social layer
(Epic 17.2-17.10) — but it's still fundamentally a single-user, single-instance tool.
There's no way to:

- Run Loomkin on your desktop and monitor/control it from your phone
- Invite a friend to observe or co-orchestrate your agent team
- Self-host Loomkin on your own infrastructure
- Have your Loomkin instance talk to someone else's
- Authenticate a long-running daemon (local or remote) with a central server

The social features exist but are trapped inside a single instance. This epic builds
the infrastructure to break that boundary: daemon authentication, cryptographic identity,
workspace sharing, and a relay architecture that makes loomkin.dev the default coordinator
while allowing anyone to self-host.

## Design Principles

1. **Agents always run locally.** The relay coordinates; it never runs agents or
   touches files. Your PDS (Personal Data Server = your Loomkin instance) is where
   computation happens.

2. **The server URL is optional.** Login is: username, password, server URL
   (defaults to `loomkin.dev`). 99% of users never change it. Self-hosters do.

3. **Permissions can only narrow, never broaden.** Macaroon token attenuation is
   cryptographic — a collaborator's token is derived from yours with added restrictions.

4. **Federation is a scaling decision, not a launch requirement.** Build centralized
   (loomkin.dev), architect for federation. `did:web` identity from day one so
   migration to full AT Protocol is a schema change, not a rewrite.

5. **Build on what exists.** The Signal bus, Channel Bridge pattern, Workspace Server,
   Presence, and Horde/Cluster infra are all foundations — extend, don't replace.

## Architecture

```
Your Machine                     loomkin.dev (or self-hosted)        Friend's Machine
┌──────────────┐                ┌──────────────────────┐            ┌──────────────┐
│ Loomkin PDS  │◄────ws────────►│ Relay                │◄────ws────►│ Loomkin PDS  │
│              │                │                      │            │              │
│ Agents       │                │ DaemonSocket         │            │ Agents       │
│ Files        │                │ WorkspaceChannel     │            │ Files        │
│ Signing key  │                │ Presence             │            │ Signing key  │
│ Data repo    │                │ Firehose             │            │ Data repo    │
│ Worktrees    │                │ Social (existing)    │            │ Worktrees    │
└──────────────┘                │ Auth (existing)      │            └──────────────┘
                                └──────────────────────┘
                                         ▲
                                         │
                                ┌────────┴───────┐
                                │ Phone/Tablet   │
                                │ (browser)      │
                                │ Monitor/approve│
                                └────────────────┘
```

## Dependencies

### New Hex Packages

| Package | Purpose |
|---------|---------|
| `{:macaroon, github: "superfly/macaroon-elixir"}` | Attenuable daemon tokens |
| `{:ed25519, "~> 1.4"}` | DID signing keys |

### Existing Infrastructure (no changes needed)

- `assent` — OAuth (already supports Google, Anthropic, OpenAI)
- `Phoenix.Token` — internal daemon auth (already available)
- `Phoenix.Presence` — online tracking (already configured)
- `Phoenix.PubSub` — event routing (already configured)
- `Horde` / `libcluster` — distributed agent supervision (already optional)
- `Jido.Signal` — event bus (already the backbone)
- Channel Bridge pattern — signal routing template
- Workspace Server — team lifecycle management
- Permission Manager — tool-scoped grants

---

## 20.1: Cryptographic Identity (did:web)

**Complexity:** Small
**Dependencies:** None
**New dep:** `ed25519`

Each Loomkin instance gets a decentralized identity: an Ed25519 keypair and a
`did:web` document. This is the foundation for signed records and future federation.

### Implementation

```elixir
defmodule Loomkin.Federation.Identity do
  @doc "Generate or load the instance's Ed25519 keypair."
  def ensure_keypair(storage_path) do
    case load_keypair(storage_path) do
      {:ok, keypair} -> {:ok, keypair}
      :not_found -> generate_and_store(storage_path)
    end
  end

  @doc "Build a DID Document for this instance."
  def did_document(did, public_key, service_endpoint) do
    %{
      "@context" => ["https://www.w3.org/ns/did/v1"],
      "id" => did,
      "verificationMethod" => [%{
        "id" => "#{did}#key-1",
        "type" => "Ed25519VerificationKey2020",
        "controller" => did,
        "publicKeyMultibase" => encode_multibase(public_key)
      }],
      "service" => [%{
        "id" => "#{did}#pds",
        "type" => "LoomkinPDS",
        "serviceEndpoint" => service_endpoint
      }]
    }
  end

  @doc "Sign a payload with the instance's private key."
  def sign(payload, private_key)

  @doc "Verify a signed payload against a public key."
  def verify(payload, signature, public_key)
end
```

### DID Format

```
# Hosted users (loomkin.dev manages the DID document)
did:web:loomkin.dev:brandon

# Self-hosted (user's domain serves the DID document)
did:web:loom.mycompany.com:alice
```

### Well-Known Endpoint

Serve the DID document at `/.well-known/did.json` (for domain-level DIDs) or
`/:username/did.json` (for user-level DIDs under a shared domain):

```elixir
# In router.ex
get "/.well-known/did.json", FederationController, :did_document
get "/:username/did.json", FederationController, :user_did_document
```

### What This Unlocks

- Every record (snippet, skill, session) can be signed by the creator
- Identity is portable — change instances, keep your DID
- Future AT Protocol compatibility requires only extending this module

### Acceptance Criteria

- [ ] Ed25519 keypair generated on first boot, persisted to configurable path
- [ ] `did:web` document generated from keypair + configured domain
- [ ] `/.well-known/did.json` endpoint serves instance DID document
- [ ] `/:username/did.json` serves per-user DID documents (multi-tenant mode)
- [ ] `sign/2` and `verify/3` work for arbitrary payloads
- [ ] Keypair survives restarts (loaded from disk)
- [ ] Tests for keygen, signing, verification, DID document format

---

## 20.2: Daemon Authentication (Macaroons)

**Complexity:** Medium
**Dependencies:** 20.1
**New dep:** `macaroon` (superfly/macaroon-elixir)

Authenticated, scoped tokens for long-running Loomkin instances connecting to a relay.
Macaroons allow progressive attenuation — a workspace owner can derive a narrower
token for a collaborator without involving the server.

### Caveat Types

```elixir
defmodule Loomkin.Federation.Macaroon do
  @caveat_types %{
    user: "user",           # DID of the token holder
    instance: "instance",   # instance identifier (machine)
    workspace: "workspace", # workspace ID
    role: "role",           # owner | collaborator | observer
    paths: "paths",         # allowed file path patterns
    expires: "expires"      # ISO8601 expiration
  }

  @doc "Mint a root macaroon for an authenticated user."
  def mint_root(user_did, secret) do
    Macaroon.create_macaroon(secret, user_did, "loomkin")
    |> Macaroon.add_first_party_caveat("user = #{user_did}")
  end

  @doc "Attenuate a macaroon with additional restrictions."
  def attenuate(macaroon, caveats) when is_list(caveats)

  @doc "Verify a macaroon against the root secret and check all caveats."
  def verify(macaroon, secret, context)

  @doc "Create a collaborator token from an owner's macaroon."
  def derive_collaborator(owner_macaroon, workspace_id, role, opts \\ [])
end
```

### Token Lifecycle

1. **Login** → server mints root macaroon (bound to user DID)
2. **Instance registration** → user attenuates with `instance` caveat
3. **Workspace access** → attenuate with `workspace` + `role` caveats
4. **Friend invitation** → owner attenuates their token with friend's scope
5. **Verification** → relay checks HMAC chain + all caveats on channel join

### Integration with Existing Auth

The macaroon system sits alongside (not replaces) the existing session auth:

- **Browser sessions** → existing Phoenix session tokens (no change)
- **Daemon connections** → macaroons (new)
- **OAuth providers** → existing assent flow (no change)

```elixir
# In Accounts context — extend login to optionally issue a daemon token
def generate_daemon_token(user, instance_id) do
  user_did = Identity.did_for_user(user)
  Macaroon.mint_root(user_did, daemon_secret())
  |> Macaroon.attenuate(instance: instance_id)
end
```

### Acceptance Criteria

- [ ] `macaroon` dep added and compiling
- [ ] Root macaroon minted on daemon token request
- [ ] Attenuation works for all caveat types (user, instance, workspace, role, paths, expires)
- [ ] Verification checks full HMAC chain + evaluates all caveats
- [ ] `derive_collaborator/4` produces a token that is strictly narrower than the source
- [ ] Expired tokens rejected
- [ ] Invalid HMAC chain rejected
- [ ] Integration with `Accounts` context for token issuance
- [ ] Token rotation: endpoint to exchange valid token for fresh one
- [ ] Tests for minting, attenuation, verification, expiry, invalid chains

---

## 20.3: Daemon Socket & Workspace Channel

**Complexity:** Medium
**Dependencies:** 20.2

A dedicated Phoenix Socket for daemon connections (separate from the LiveView socket).
Daemons authenticate with macaroons on connect. Channels are scoped to workspaces
with macaroon caveat enforcement on join.

### Socket

```elixir
# lib/loomkin_web/daemon_socket.ex
defmodule LoomkinWeb.DaemonSocket do
  use Phoenix.Socket

  channel "workspace:*", LoomkinWeb.WorkspaceChannel
  channel "presence:*", LoomkinWeb.PresenceChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Loomkin.Federation.Macaroon.verify(token, daemon_secret(), %{}) do
      {:ok, claims} ->
        {:ok, assign(socket, :claims, claims)}
      {:error, _reason} ->
        :error
    end
  end

  @impl true
  def id(socket), do: "daemon:#{socket.assigns.claims.instance}"
end
```

### Workspace Channel

```elixir
# lib/loomkin_web/channels/workspace_channel.ex
defmodule LoomkinWeb.WorkspaceChannel do
  use LoomkinWeb, :channel

  @impl true
  def join("workspace:" <> workspace_id, _params, socket) do
    claims = socket.assigns.claims

    case verify_workspace_access(claims, workspace_id) do
      {:ok, role} ->
        send(self(), :after_join)
        {:ok, %{role: role}, assign(socket, :workspace_id, workspace_id)}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track daemon presence in workspace
    Presence.track(socket, socket.assigns.claims.instance, %{
      role: socket.assigns.role,
      joined_at: System.system_time(:second)
    })
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  # Forward workspace events to connected daemons
  @impl true
  def handle_info({:workspace_event, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  defp verify_workspace_access(claims, workspace_id) do
    # Check macaroon caveats allow this workspace
    Loomkin.Federation.Macaroon.check_caveat(claims, :workspace, workspace_id)
  end
end
```

### Endpoint Configuration

```elixir
# In endpoint.ex — add alongside existing LiveView socket
socket "/daemon", LoomkinWeb.DaemonSocket,
  websocket: [
    connect_info: [:peer_data, :x_headers],
    timeout: 120_000
  ]
```

### Event Bridge

Connect the existing Signal bus to the daemon channel so connected daemons
see agent activity, decisions, task updates:

```elixir
defmodule Loomkin.Federation.EventBridge do
  @doc """
  Subscribes to workspace signals and broadcasts them to the
  workspace channel. Similar pattern to Channels.Bridge but
  targets Phoenix Channels instead of Telegram/Discord adapters.
  """
  def subscribe_workspace(workspace_id) do
    topics = [
      "team.#{workspace_id}.**",
      "agent.#{workspace_id}.**",
      "session.#{workspace_id}.**"
    ]
    Enum.each(topics, &Loomkin.Signals.subscribe/1)
  end
end
```

### Acceptance Criteria

- [ ] `DaemonSocket` accepts WebSocket connections at `/daemon`
- [ ] Macaroon verified on connect; invalid tokens rejected
- [ ] `WorkspaceChannel` join enforces workspace caveat from macaroon
- [ ] Role assigned from macaroon claims (owner/collaborator/observer)
- [ ] Presence tracked per daemon in workspace
- [ ] Workspace events (agent activity, tasks, decisions) pushed to channel
- [ ] EventBridge subscribes to Signal bus and forwards to channel
- [ ] Observer role receives events but cannot push commands
- [ ] Collaborator role can push commands (future: task approval, agent steering)
- [ ] Tests for connect, join, rejection, event forwarding, presence

---

## 20.4: Server URL & Federated Login

**Complexity:** Small
**Dependencies:** 20.1, 20.2

Add the server URL field to the login flow. Defaults to `loomkin.dev`. Users who
self-host change it to their domain. The field is optional and hidden under "Advanced."

### Login Flow

```
1. User enters: username/email, password
2. (Optional) User expands "Advanced" → changes server URL
3. Client resolves server URL → fetches server metadata
4. Auth request sent to the resolved server
5. Server returns session token + daemon token (if requested)
6. Client stores server URL in local config for future sessions
```

### Server Metadata Endpoint

Each Loomkin instance advertises its capabilities:

```elixir
# GET /.well-known/loomkin.json
%{
  "name" => "Loomkin",
  "version" => Application.spec(:loomkin, :vsn),
  "auth_methods" => ["password", "magic_link", "oauth:google", "oauth:anthropic"],
  "daemon_socket" => "/daemon",
  "did" => "did:web:loomkin.dev",
  "registration_open" => true
}
```

### Config Storage

```elixir
# config/runtime.exs — self-hosters set their domain
config :loomkin, :instance_domain,
  System.get_env("LOOMKIN_DOMAIN", "loomkin.dev")
```

The `instance_domain` determines:
- DID generation (`did:web:#{domain}:#{username}`)
- Server metadata endpoint
- Handle resolution

### UI Changes

Modify existing login LiveView (already built in Epic 17.1):
- Add collapsible "Advanced" section below password field
- Server URL text input, defaulting to `loomkin.dev`
- Validate server URL by fetching `/.well-known/loomkin.json`
- Store last-used server URL in browser localStorage

### Acceptance Criteria

- [ ] `/.well-known/loomkin.json` endpoint returns server metadata
- [ ] Login form has optional "Advanced" section with server URL field
- [ ] Server URL defaults to `loomkin.dev`
- [ ] Server URL stored in localStorage, persists across sessions
- [ ] Auth request sent to configured server URL
- [ ] Invalid server URL shows clear error ("Could not connect to server")
- [ ] `LOOMKIN_DOMAIN` env var configures instance identity
- [ ] DID generation uses configured domain
- [ ] Tests for metadata endpoint, URL validation

---

## 20.5: Workspace Sharing & Collaboration

**Complexity:** Large
**Dependencies:** 20.2, 20.3

The core collaboration primitive: invite a friend to your workspace with a scoped
role. Their agents run on their machine against an isolated git worktree. They see
your agent activity via the relay.

### Invitation Flow

```elixir
defmodule Loomkin.Federation.Collaboration do
  @doc "Create an invitation for a user to join a workspace."
  def create_invite(owner_scope, workspace, invitee_handle, role, opts \\ []) do
    # 1. Resolve invitee's DID from handle
    # 2. Attenuate owner's macaroon with workspace + role + expiry caveats
    # 3. Create Invite record in DB
    # 4. Push invite notification via relay (if invitee is connected)
    # 5. Return invite with scoped token
  end

  @doc "Accept an invitation — join the workspace."
  def accept_invite(invitee_scope, invite) do
    # 1. Verify invite token is valid and not expired
    # 2. Create WorkspaceMembership record
    # 3. Set up worktree for invitee (if same-machine collaboration)
    # 4. Connect invitee's daemon to workspace channel
  end

  @doc "Create an isolated git worktree for a collaborator."
  def create_worktree(workspace, collaborator) do
    # 1. Determine base project path
    # 2. git worktree add ../project-{collaborator} -b {collaborator}/collab
    # 3. Register worktree path in workspace membership
    # 4. Return worktree path (used as project_path for collaborator's agents)
  end

  @doc "Clean up a collaborator's worktree on leave/revoke."
  def remove_worktree(workspace, collaborator) do
    # 1. git worktree remove ../project-{collaborator}
    # 2. Optionally delete the branch
    # 3. Clear workspace membership
  end
end
```

### Schemas

```elixir
# Workspace membership — who has access to which workspace
defmodule Loomkin.Schemas.WorkspaceMembership do
  schema "workspace_memberships" do
    belongs_to :workspace, Loomkin.Schemas.Workspace
    belongs_to :user, Loomkin.Schemas.User
    field :role, Ecto.Enum, values: [:owner, :collaborator, :observer]
    field :worktree_path, :string        # nil for remote collaborators
    field :token_nonce, :string          # for macaroon revocation
    field :invited_by_id, :binary_id
    timestamps(type: :utc_datetime)
  end
end

# Invitation — pending workspace invites
defmodule Loomkin.Schemas.Invite do
  schema "invites" do
    belongs_to :workspace, Loomkin.Schemas.Workspace
    belongs_to :inviter, Loomkin.Schemas.User
    field :invitee_handle, :string       # handle or email
    field :invitee_did, :string          # resolved DID (if known)
    field :role, Ecto.Enum, values: [:collaborator, :observer]
    field :token, :string                # encrypted macaroon
    field :status, Ecto.Enum, values: [:pending, :accepted, :declined, :expired]
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
```

### Roles

| Role | See agents | See files | Run agents | Push commands | Manage members |
|------|-----------|-----------|------------|---------------|----------------|
| **Owner** | yes | yes | yes | yes | yes |
| **Collaborator** | yes | own worktree | yes (own worktree) | yes | no |
| **Observer** | yes | read-only | no | no | no |

### Worktree Lifecycle

```
/invite alice workspace:loom role:collaborator
  │
  ├─ create_invite() → mint scoped macaroon
  │
  ├─ alice accepts
  │   ├─ create_worktree() → git worktree add ../loom-alice -b alice/collab
  │   ├─ create WorkspaceMembership (role: :collaborator, worktree_path: ...)
  │   └─ alice's agents get project_path = worktree_path
  │       └─ safe_path!/2 jails ops to this path (existing infra)
  │
  ├─ alice works → commits to alice/collab branch
  │
  ├─ brandon reviews → merge via git flow
  │
  └─ /revoke alice
      ├─ remove_worktree() → git worktree remove ../loom-alice
      ├─ revoke macaroon (by nonce)
      └─ delete WorkspaceMembership
```

### UI: Workspace Members Panel

Add a "Members" section to the workspace view (only visible to owner):

```
┌──────────────────────────┐
│ MEMBERS                  │
│                          │
│ ● brandon (owner)        │
│ ● alice (collaborator)   │
│   branch: alice/collab   │
│   [Revoke]               │
│ ○ bob (observer)         │
│   [Revoke]               │
│                          │
│ [+ Invite]               │
└──────────────────────────┘
```

### Acceptance Criteria

- [ ] `workspace_memberships` table with role, worktree_path, token_nonce
- [ ] `invites` table with status lifecycle (pending → accepted/declined/expired)
- [ ] `create_invite/5` mints scoped macaroon, creates invite record
- [ ] `accept_invite/2` creates membership, sets up worktree
- [ ] `create_worktree/2` runs `git worktree add`, returns path
- [ ] `remove_worktree/2` cleans up worktree + branch
- [ ] Collaborator's agents use worktree as `project_path`
- [ ] `safe_path!/2` naturally jails collaborator file ops (existing behavior)
- [ ] Macaroon revocation by nonce on `/revoke`
- [ ] Members panel in workspace UI (owner only)
- [ ] Invite modal with handle input, role selector, expiry
- [ ] PubSub events for member join/leave broadcast to workspace channel
- [ ] Tests for full invite lifecycle, worktree creation/cleanup, role enforcement

---

## 20.6: Authorized PubSub

**Complexity:** Small
**Dependencies:** 20.3, 20.5

Wrap Phoenix PubSub with authorization checks. The existing PubSub has no access
control — any process that knows a topic string can subscribe. This adds a thin
layer that checks workspace membership before allowing subscriptions.

### Implementation

```elixir
defmodule Loomkin.Federation.AuthorizedPubSub do
  alias Phoenix.PubSub
  alias Loomkin.Federation.Collaboration

  @pubsub Loomkin.PubSub

  def subscribe(scope, "workspace:" <> workspace_id = topic) do
    if Collaboration.member?(scope, workspace_id) do
      PubSub.subscribe(@pubsub, topic)
    else
      {:error, :unauthorized}
    end
  end

  def subscribe(_scope, topic) do
    # Non-workspace topics use existing behavior (no auth)
    PubSub.subscribe(@pubsub, topic)
  end

  def broadcast(scope, "workspace:" <> workspace_id = topic, message) do
    if Collaboration.can_broadcast?(scope, workspace_id) do
      PubSub.broadcast(@pubsub, topic, message)
    else
      {:error, :unauthorized}
    end
  end
end
```

### Integration Points

- `WorkspaceChannel.join/3` — uses authorized subscribe (already macaroon-gated)
- `EventBridge` — subscribes with system scope (always authorized)
- `SocialPanelComponent` — subscribes to followed users' presence (existing, unchanged)

### Acceptance Criteria

- [ ] `AuthorizedPubSub.subscribe/2` checks membership for workspace topics
- [ ] `AuthorizedPubSub.broadcast/3` checks broadcast permission
- [ ] Non-workspace topics pass through without auth (backward compatible)
- [ ] WorkspaceChannel uses authorized subscribe
- [ ] Observer role can subscribe but not broadcast
- [ ] Tests for authorized/unauthorized subscribe and broadcast

---

## 20.7: Self-Hosting Configuration

**Complexity:** Small
**Dependencies:** 20.4

Make Loomkin deployable on user-owned infrastructure with minimal configuration.
The same binary that runs loomkin.dev runs on a self-hosted server.

### Environment Variables

```bash
# Required
DATABASE_URL=postgres://...
SECRET_KEY_BASE=...                # mix phx.gen.secret
LOOMKIN_DOMAIN=loom.mycompany.com  # your domain (DID + handle resolution)

# Optional
MULTI_TENANT=true                  # enable auth wall + social features
REGISTRATION_OPEN=true             # allow new signups (default: true)
MACAROON_SECRET=...                # daemon token secret (auto-generated if missing)
PHX_HOST=loom.mycompany.com        # Phoenix host config
PORT=4000                          # HTTP port
```

### Docker

```dockerfile
# Dockerfile (multi-stage, minimal)
FROM hexpm/elixir:1.18-erlang-27-alpine AS build
# ... standard Phoenix release build ...

FROM alpine:3.20
COPY --from=build /app/_build/prod/rel/loomkin ./
CMD ["bin/loomkin", "start"]
```

```yaml
# docker-compose.yml
services:
  loomkin:
    image: loomkin/loomkin:latest
    environment:
      DATABASE_URL: postgres://postgres:postgres@db/loomkin
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      LOOMKIN_DOMAIN: ${LOOMKIN_DOMAIN:-localhost}
      MULTI_TENANT: "true"
    ports:
      - "4000:4000"
    depends_on:
      - db

  db:
    image: postgres:17-alpine
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: loomkin
      POSTGRES_PASSWORD: postgres

volumes:
  pgdata:
```

### Health Check Endpoint

```elixir
# GET /health — no auth required
%{
  "status" => "ok",
  "version" => "0.1.0",
  "database" => "connected",
  "uptime_seconds" => System.monotonic_time(:second)
}
```

### Self-Hosting Guide

Create `docs/self-hosting.md` with:
- Prerequisites (Elixir 1.18+ or Docker)
- Quick start (docker-compose up)
- Configuration reference (all env vars)
- HTTPS setup (Caddy/nginx reverse proxy)
- Backup/restore (pg_dump)
- Updating

### Acceptance Criteria

- [ ] `mix phx.gen.release` configured with Dockerfile
- [ ] docker-compose.yml with Loomkin + Postgres
- [ ] All configuration via environment variables
- [ ] `LOOMKIN_DOMAIN` drives DID generation and handle resolution
- [ ] `REGISTRATION_OPEN` flag controls whether new accounts can be created
- [ ] `/health` endpoint returns status without auth
- [ ] `/.well-known/loomkin.json` works on self-hosted instances
- [ ] `docs/self-hosting.md` written
- [ ] Tested: `docker-compose up` → register → login → create workspace → agents work

---

## 20.8: Mobile Control Plane

**Complexity:** Medium
**Dependencies:** 20.3, 20.5

Make the workspace view usable on mobile browsers. Not a native app — just
responsive design + the daemon socket for real-time updates. Your phone becomes a
window into what your agents are doing on your desktop.

### What Mobile Gets

- **Agent status cards** — see which agents are active, thinking, idle
- **Comms feed** — watch inter-agent communication in real-time
- **Task list** — see task progress, approve/reject pending tasks
- **Decision graph** — read-only view of decisions made
- **Cost tracker** — running LLM spend for the session
- **Quick actions** — pause all agents, cancel task, approve permission request

### What Mobile Does NOT Get

- Full file editor (too small, not the right UX)
- Agent configuration (use desktop)
- Skill/snippet editing (use desktop)

### Implementation

This is primarily CSS/responsive work on existing LiveView components, plus
ensuring the daemon socket connection works from a mobile browser pointed at
the relay.

Key changes:
1. **Responsive breakpoints** on WorkspaceLive — stack panels vertically on small screens
2. **Collapsible panels** — only show one panel at a time on mobile (agent cards OR comms OR tasks)
3. **Bottom navigation** — tab bar for switching between panels
4. **Touch targets** — ensure buttons/actions are 44px+ tap targets
5. **PWA manifest** — add to home screen support (icon, splash, standalone mode)

### Acceptance Criteria

- [ ] WorkspaceLive renders usably on 375px-wide viewport
- [ ] Agent status cards stack vertically, one column
- [ ] Comms feed scrollable with touch
- [ ] Task list with approve/reject actions accessible on mobile
- [ ] Cost tracker visible
- [ ] Bottom tab bar for panel switching
- [ ] PWA manifest (`manifest.json`) with app icon
- [ ] `<meta name="viewport">` properly configured
- [ ] Tested on iOS Safari and Android Chrome

---

## Implementation Order

```
20.1 Identity (did:web, Ed25519)
  │
  └─► 20.2 Daemon Auth (macaroons)
        │
        ├─► 20.3 Daemon Socket & Workspace Channel
        │     │
        │     ├─► 20.5 Workspace Sharing & Collaboration
        │     │     │
        │     │     ├─► 20.6 Authorized PubSub
        │     │     │
        │     │     └─► 20.8 Mobile Control Plane
        │     │
        │     └─► (20.6 can start here too)
        │
        └─► 20.4 Server URL & Federated Login
              │
              └─► 20.7 Self-Hosting Configuration
```

**Recommended build order:**

1. **20.1** — Identity (small, foundational, unblocks everything)
2. **20.2** — Daemon auth (medium, core security primitive)
3. **20.3** — Daemon socket + channels (medium, first working daemon connection)
4. **20.4** — Server URL field (small, enables self-hosting story)
5. **20.5** — Workspace sharing (large, the flagship feature)
6. **20.6** — Authorized PubSub (small, hardens 20.5)
7. **20.7** — Self-hosting config (small, Docker + docs)
8. **20.8** — Mobile control plane (medium, responsive + PWA)

**Estimated total: 8 sub-tasks across 3 layers (identity, transport, collaboration).**

---

## Future Work (Not In This Epic)

These are enabled by Epic 20 but intentionally deferred:

- **Full AT Protocol interop** — Lexicon schemas, XRPC endpoints, Bluesky integration
- **Inter-instance federation** — your Loomkin talks to mine (relay-to-relay)
- **Feed generators** — algorithmic skill/solution recommendation (Pass fingerprinting)
- **Labelers** — community trust scoring on shared content
- **Agent-to-agent signing** — cryptographic provenance on inter-agent messages
- **Workspace-level permissions in Bodyguard** — formal policy module (currently manual)
- **Organization-scoped workspaces** — share workspaces within an org (schemas exist, need wiring)
- **Notifications system** — persistent notification DB for favorites, forks, invites

---

## Risks & Open Questions

1. **Macaroon library maturity** — `superfly/macaroon-elixir` is used by Fly.io in production
   but is not on Hex. Pin to a specific commit. If it proves problematic, fall back to
   Phoenix.Token with manual scope checks (less elegant but functional).

2. **Git worktree limits** — worktrees share the object database. Many worktrees on a large
   repo could stress git gc. For 2-5 collaborators this is fine; at scale, consider
   shallow clones instead.

3. **Relay as single point of failure** — if loomkin.dev goes down, daemon connections drop.
   Agents continue running locally (they don't depend on the relay). Reconnect on recovery.
   Self-hosting mitigates this.

4. **Mobile PWA limitations** — iOS Safari restricts background WebSocket connections.
   The mobile view will need to reconnect on foreground. LiveView's reconnect handling
   already manages this gracefully.

5. **DID key rotation** — `did:web` doesn't natively support key rotation (unlike `did:plc`).
   If a signing key is compromised, the user must update their DID document. For v1 this
   is acceptable. Upgrade to `did:plc` if key rotation becomes a real need.

6. **Collaborator file conflicts** — two collaborators editing the same file in different
   worktrees will conflict on merge. This is normal git behavior. The merge happens via
   standard git flow, not Loomkin-managed OT/CRDT. Good enough for 2-5 people.
