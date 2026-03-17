# Epic 18: Closing the Loop

## Overview

When Peter Steinberger built OpenClaw, he solved the "open loop" problem: humans were manually shuttling errors between AI and terminal. His fix — give the agent CLI access so it can write → run → read errors → fix → repeat autonomously.

Loomkin already goes further. Our healing pipeline (Epic 14) separates diagnosis from repair using ephemeral agents with fresh context. But the system is **reactive** — it only kicks in after errors occur. And our session/context architecture, while functional, wasn't designed for the autonomous verification cycles that true loop-closing demands.

This epic transforms Loomkin from a **reactive self-healer** into a **proactive self-verifying ecosystem** across three pillars:

1. **Context Keepers** — From dumb storage to intelligent verification memory with lifecycle management, staleness detection, failure patterns, and a dedicated inspection UI
2. **Session Architecture** — Relocate session UI to reflect its conversation-level role, introduce Workspace abstraction for persistent agent state
3. **Verification Ecosystem** — Proactive upstream verification, multi-tier validation chains, and self-introspection

### Why This Matters

OpenClaw closes a single-agent loop. Loomkin can close a **multi-agent verification ecosystem** — where agents verify each other's work, learn from past failures, and maintain confidence scores across decision chains. BEAM/OTP gives us process isolation (crashes don't cascade), lightweight processes (~2KB per ephemeral verifier), preemptive scheduling (verification never starves), and supervision trees (automatic restart with backoff).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      WORKSPACE (persistent)                  │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ Team Fleet   │    │ Task Journal │    │ Context       │  │
│  │ (persistent) │    │ (checkpointed│    │ Library       │  │
│  │              │    │  to DB)      │    │ (keepers +    │  │
│  │ Agent A ─────┤    │              │    │  failure mem) │  │
│  │ Agent B ─────┤    │ task_1: done │    │              ┌┤  │
│  │ Verifier ────┤    │ task_2: wip  │    │ keeper_1: 🟢 ││  │
│  │ Diagnostician│    │ task_3: spec │    │ keeper_2: 🟡 ││  │
│  └──────────────┘    └──────────────┘    │ keeper_3: 🔴 ││  │
│                                          │ failures: 📋 ││  │
│  ┌──────────────────────────────────┐    └──────────────┘│  │
│  │ Verification Loop (autonomous)   │                     │  │
│  │                                  │                     │  │
│  │ write → test → classify error    │                     │  │
│  │   → diagnose → fix → re-test    │←── failure memory   │  │
│  │   → confidence score → cascade   │    keepers feed     │  │
│  │   → upstream verify dependents   │    learning loop    │  │
│  └──────────────────────────────────┘                     │  │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ UserSession  │  │ UserSession  │  │ UserSession  │      │
│  │ (device A)   │  │ (device B)   │  │ (future)     │      │
│  │ ephemeral    │  │ ephemeral    │  │              │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

## Phase 1: Context Keeper Intelligence (1.5 weeks)

The foundation. Keepers become observable, trackable, and self-aware.

### 1.1 Keeper Metadata Expansion

**Files:** `context_keeper.ex`, migration

Add tracking fields to keeper state and DB schema:

| Field | Type | Purpose |
|-------|------|---------|
| `last_accessed_at` | `utc_datetime` | When was this keeper last queried? |
| `access_count` | `integer` | How many times has it been retrieved? |
| `last_agent_name` | `string` | Most recent agent to read this keeper |
| `retrieval_mode_histogram` | `map` | `%{raw: 3, smart: 7, synthesize: 1}` |
| `summary` | `string` | LLM-generated abstract (for keepers > 5K tokens) |
| `relevance_score` | `float` | 0.0-1.0 relevance to current team focus |
| `confidence` | `float` | 0.0-1.0 based on success/miss ratio |
| `success_count` | `integer` | Times retrieval was useful |
| `miss_count` | `integer` | Times retrieval was not useful |

Update `context_retrieve` tool to increment counters on every access.

### 1.2 Staleness Detection

**File:** `context_keeper.ex` (new `compute_staleness/1` function)

Four-factor scoring model (each 0-25, total 0-100):

- **Time decay**: 5 points per hour since creation (1 week = 25 pts, capped)
- **Access decay**: Points accumulate when unused (12h no access = 25 pts, resets on query)
- **Relevance decay**: Topic overlap vs. team's current focus areas (0-25 pts)
- **Confidence decay**: Based on success/miss ratio (0-25 pts)

State machine:
```
Fresh (0-24) → Warm (25-49) → Stale (50-74) → Expired (75-100)
  🟢              🟡              🟠              🔴
```

Auto-archive: keepers with staleness >= 75 AND created > 7 days ago move to archived status. Retained in DB but excluded from active queries.

Staleness computed lazily on `list_keepers` and on a 30-minute sweep.

### 1.3 Failure Memory Keepers

**Files:** `context_keeper.ex`, `agent_loop.ex`, new `failure_memory.ex`

New keeper type: `metadata.type = "failure_memory"`

- Auto-spawned on classified tool errors in `agent_loop.ex`
- Stores: error category, tool name, input args, error message, fix attempted, timestamp, agent name
- Topic format: `"failures:#{agent_name}"`

**Learning loop**: On agent bootstrap, search for failure memory keepers:
```elixir
# In agent init
failures = ContextRetrieval.search(team_id, "failures:#{agent_name}")
summary = ContextRetrieval.synthesize(team_id, "What errors occurred before? What patterns? What fixed them?")
# Inject into system prompt as "lessons learned"
```

This makes agents smarter over time — they avoid known pitfalls and escalate novel errors.

### 1.4 Context Library UI

**Files:** new `context_library_component.ex`, `workspace_live.ex`

A dedicated inspection interface for keepers, accessible as a tab/panel in WorkspaceLive.

**Layout**: Master-detail. Left panel = sortable keeper list. Right panel = inspector.

**List columns**:
| Column | Sortable | Notes |
|--------|----------|-------|
| Topic | yes | Truncated, tooltip for full |
| Source Agent | yes | Who created it |
| Size | yes | Token count |
| Created | yes | Relative time |
| Last Accessed | yes | Relative time, "never" if unused |
| Queries | yes | access_count |
| Staleness | yes | Color-coded badge (🟢🟡🟠🔴) |
| Confidence | yes | Percentage with color |

**Inspector panel** (right side, shown on row click):
- Full metadata grid
- Staleness breakdown visualization (stacked bar showing each decay factor)
- Message preview (first 2 messages, expandable)
- Actions: Refresh Staleness, Archive, Delete, Copy ID, Export JSON

**Filters**: Status (Active/Archived), Staleness state, Source Agent, Time window
**Search**: Debounced free-text on topic/agent/id

Use LiveView streams for the keeper list (supports 1000+ keepers without memory issues). Subscribe to `"team:#{team_id}:keepers"` PubSub topic for real-time updates.

## Phase 2: Session Relocation & Workspace Foundation (2-3 weeks)

### 2.1 Relocate Session Switcher

**Files:** `session_switcher_component.ex`, `workspace_live.ex`

The session switcher currently sits in the **top-right header** alongside model selector, settings, and other top-level controls. This makes it look like a primary navigation element when it's really just a conversation switcher.

**Move to**: Inside the conversation/chat area — either:
- (A) A collapsible drawer at the top of the message feed (above the first message), or
- (B) A small tab strip at the top of the chat column that shows the current session name with a dropdown

The header should contain workspace-level controls only (model, settings, project). The session switcher belongs within the conversation pane, signaling "this is one of many conversations within your workspace."

**Changes:**
1. Remove `<.live_component module={SessionSwitcherComponent} ...>` from header (workspace_live.ex lines 4129-4135)
2. Place it at the top of the chat/message column instead
3. Restyle: smaller, more subtle — thin bar with session name + dropdown chevron, muted colors
4. Add session count badge: "Session 3 of 7"

### 2.2 Workspace Abstraction

**Files:** new `lib/loomkin/workspace.ex`, new `lib/loomkin/workspace/` directory, migration

Introduce a persistent layer above sessions:

```elixir
defmodule Loomkin.Workspace do
  use Ecto.Schema

  schema "workspaces" do
    field :name, :string
    field :project_paths, {:array, :string}  # multi-project support
    field :team_id, :string
    field :status, Ecto.Enum, values: [:active, :hibernated, :archived]

    has_many :sessions, Loomkin.Session.Schema
    has_many :task_journal_entries, Loomkin.Workspace.TaskJournalEntry

    timestamps()
  end
end
```

**Workspace GenServer**: Owns team lifetime. When a UserSession connects, it attaches to an existing workspace (or creates one). When the UserSession disconnects, the workspace persists — agents keep running.

**Task journal**: Persistent log of all task state changes. On workspace resumption, rebuild in-progress tasks from the journal.

### 2.3 Decouple Team Lifetime from Session

**Files:** `session.ex`, `manager.ex`, `workspace.ex`

Today: session starts → team starts → session ends → team dies.
After: workspace starts → team starts → session connects/disconnects freely → team persists until workspace hibernates.

Key changes:
- Team registered under workspace_id, not session_id
- Session mount looks up workspace, attaches to existing team
- Session unmount does NOT kill team (workspace owns it)
- Add `Workspace.hibernate/1` for explicit team shutdown + checkpoint

## Phase 3: Verification Ecosystem (3-4 weeks)

### 3.1 Upstream Verifier

**Files:** new `lib/loomkin/verification/upstream_verifier.ex`

Spawned automatically when a task declares a dependency on another task's output.

```
Task A completes → signal :task_completed
    → Upstream Verifier spawns (ephemeral agent, fresh context)
    → Runs acceptance checks: compile? tests pass? lint clean? spec met?
    → Returns {passed: bool, confidence: 0-100, details: map}
    → If passed: dependent Task B unblocks
    → If failed: route to healing pipeline
```

Budget: 25% of task budget. Timeout: 2 minutes. Non-blocking for the completing agent.

### 3.2 Verification Chains

**Files:** `upstream_verifier.ex`, `healing/orchestrator.ex`

Multi-tier validation for high-stakes work:

```
Agent writes code
    → Upstream Verifier (compile + test)
    → Peer Reviewer (logic + architecture)      ← enhanced peer_review tool
    → Integration Verifier (cross-agent compat)  ← new
    → Decision graph confidence updated
```

Each tier adds confidence. All tiers passing = 95%+ confidence. Any failure cascades uncertainty to downstream decision nodes.

### 3.3 Self-Introspection Tools

**Files:** new `lib/loomkin/tools/introspect.ex`

New tool: `introspect_decision_history`
- Query: "Why did I make decision X?"
- Returns: assumptions, rationale, confidence trajectory, iteration number
- Enables: agent at iteration 8 detects circular reasoning from iterations 2-5, resets approach

New tool: `introspect_failure_patterns`
- Query: "What errors have I hit before?"
- Returns: synthesized failure memory from keepers
- Enables: avoid known pitfalls on retry

### 3.4 Verification Loop GenServer

**Files:** new `lib/loomkin/verification/loop.ex`

Autonomous long-running verification cycle:

```elixir
defmodule Loomkin.Verification.Loop do
  use GenServer

  defstruct [
    :workspace_id,
    :task_id,
    :test_command,
    :success_criteria,
    :max_iterations,
    :current_iteration,
    :results,
    :confidence,
    :checkpoint_path
  ]

  # Checkpoints every 5 iterations
  # Survives session disconnects (workspace-owned)
  # Escalates on timeout (default: 30 min)
  # UserSession can query status or inject steering
end
```

This is the heart of "closing the loop" — an autonomous GenServer that iterates write → test → diagnose → fix → re-test without any human involvement, feeding failure memory keepers as it goes.

## Phase 4: Intelligence Layer (2-3 weeks, stretch)

### 4.1 Keeper Auto-Summarization
Keepers > 5K tokens get an LLM-generated abstract. Agents compare abstracts (cheap) before full retrieval (expensive).

### 4.2 Keeper Merging
Detect keepers with > 60% topic overlap. Consolidate on cleanup sweep. Show merge recommendations in Context Library UI.

### 4.3 Continuous Monitoring
Scheduled re-verification of work products (configurable, default 24h). Regression detected → confidence drops → healing pipeline activates.

### 4.4 Adaptive Loop Control
Cost tracking per verification loop. Budget enforcement. Loop detection (same test 5+ times → escalate). Autonomous specialist selection.

## Implementation Order

| # | Task | Phase | Effort | Blocks |
|---|------|-------|--------|--------|
| 1 | Keeper metadata expansion (schema + migration) | 1.1 | 5h | 2, 3, 6 |
| 2 | Staleness detection (`compute_staleness/1`) | 1.2 | 1.5d | 6 |
| 3 | Failure memory keeper type | 1.3 | 3d | 8 |
| 4 | Bootstrap learning loop (agent init reads failures) | 1.3 | 2d | 3 |
| 5 | Context Library inspection UI | 1.4 | 1w | 1, 2 |
| 6 | Auto-archive expired keepers | 1.2 | 1d | 2 |
| 7 | Relocate session switcher from header to chat pane | 2.1 | 2d | — |
| 8 | Workspace schema + GenServer | 2.2 | 1.5w | — |
| 9 | Task journal table + persistence | 2.2 | 3d | 8 |
| 10 | Decouple team lifetime from session | 2.3 | 3d | 8 |
| 11 | Multi-project support in workspace | 2.2 | 3d | 8 |
| 12 | Upstream Verifier agent | 3.1 | 4d | 8 |
| 13 | Acceptance checks tool | 3.1 | 4d | 12 |
| 14 | Verification chains (multi-tier) | 3.2 | 1w | 12, 13 |
| 15 | Self-introspection tools | 3.3 | 3d | 3 |
| 16 | VerificationLoop GenServer | 3.4 | 1w | 8, 12 |
| 17 | Keeper auto-summarization | 4.1 | 1d | 1 |
| 18 | Keeper merging | 4.2 | 2d | 1, 2 |
| 19 | Continuous monitoring | 4.3 | 4d | 12, 16 |
| 20 | Adaptive loop control | 4.4 | 3d | 16 |

## Parallelization Strategy (for Claude teams)

Phase 1 and Phase 2 are **fully parallel** — different files, different domains:

- **Track A** (2-3 agents): Context Keepers (tasks 1-6) → Context Library UI (task 5)
- **Track B** (2-3 agents): Session relocation (task 7) + Workspace foundation (tasks 8-11)
- **Track C** (after A+B): Verification ecosystem (tasks 12-16) → Intelligence (17-20)

## Comparison: OpenClaw vs. Loomkin After Epic 18

| Capability | OpenClaw | Loomkin (after) |
|-----------|----------|-----------------|
| Agent runs code & reads errors | yes | yes |
| Separate diagnosis from repair | no | yes (ephemeral agents) |
| Crash isolation | no | yes (BEAM processes) |
| Multi-agent verification | no | yes (upstream + peer + integration) |
| Failure memory / learning | no | yes (failure memory keepers) |
| Confidence propagation | no | yes (decision graph cascades) |
| Proactive verification | no | yes (upstream verifier) |
| Autonomous long-running loops | limited | yes (VerificationLoop GenServer) |
| Keeper inspection / observability | n/a | yes (Context Library UI) |
| Persistent across sessions | no | yes (Workspace layer) |
| Lightweight ephemeral agents | expensive (threads) | yes (~2KB BEAM processes) |
| Human steering mid-loop | limited | yes (checkpoints + session overlay) |

## Success Criteria

- [ ] Keepers track access count, staleness, and confidence
- [ ] Context Library UI shows all keepers with staleness badges and actions
- [ ] Failure memory keepers auto-created on errors, read on agent bootstrap
- [ ] Session switcher moved out of header into conversation pane
- [ ] Workspace persists team state across session disconnects
- [ ] Upstream Verifier catches issues before dependent tasks proceed
- [ ] VerificationLoop runs 10+ iterations autonomously without human input
- [ ] Agents avoid previously-encountered errors via failure memory
