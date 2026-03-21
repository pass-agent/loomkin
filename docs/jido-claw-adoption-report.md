# jido_claw Feature Adoption Report for Loomkin

> Comparative analysis conducted 2026-03-21 by 5-agent investigation team.
> Source: [github.com/robertohluna/jido_claw](https://github.com/robertohluna/jido_claw) v0.3.0

---

## Executive Summary

jido_claw is a full-stack AI agent platform built on the same Jido/Elixir/OTP stack as Loomkin. Both share `req_llm`, `jido_ai`, and Phoenix LiveView foundations. jido_claw excels in **execution sandboxing**, **solution caching**, and **workflow formalization**, while Loomkin has superior **team hierarchy**, **decision graphs**, **cross-team messaging**, and **conversation agents**.

This report identifies **14 adoptable features** across 5 subsystems, prioritized by impact and implementation cost.

---

## Priority Matrix

| # | Feature | Priority | Effort | Subsystem |
|---|---------|----------|--------|-----------|
| 1 | Runner concurrency limits | **P0** | 2 days | Forge |
| 2 | Persistent shell sessions | **P0** | 3 days | Forge |
| 3 | Secret redaction (multi-layer) | **P0** | 2 days | Security |
| 5 | Complexity scores as orchestration signals | **P1** | 1 day | Reasoning |
| 6 | CoD for internal ReAct deliberation | **P1** | 1 day | Reasoning |
| 7 | Output coalescing (streaming buffer) | **P1** | 2 days | Forge |
| 8 | WorkflowRun/Step audit trail | **P1** | 5 days | Workflow |
| 9 | Retry lineage tracking | **P1** | 2 days | Workflow |
| 10 | Swarm control tools (list/kill agents) | **P1** | 2 days | Swarm |
| 11 | Heartbeat monitoring | **P1** | 1 day | Swarm |
| 12 | Virtual Filesystem (multi-backend) | **P2** | 4 days | VFS |
| 13 | Approval gates (workflow dependencies) | **P2** | 3 days | Workflow |
| 14 | Cron scheduling daemon | **P2** | 3 days | Workflow |

---

## Detailed Feature Analysis

### 1. Forge Engine — Execution Sandboxing

**What jido_claw does:**
- 4 runner types (shell, claude_code, workflow, custom) with per-type concurrency caps
- Shell.SessionManager: persistent CWD + env vars across commands
- Output coalescing: 50ms buffered emission, 64KB per chunk
- Sprite containers for true process isolation
- Session registry for tracking/cleanup of active executions

**What Loomkin has:**
- Basic tool sandboxing: 15 blocklist patterns, path containment, 10KB output limit
- No persistent shell state — CWD/env reset every command
- No concurrency limits on tool execution
- No output streaming/buffering — full output collected then emitted

**Gap analysis:**

| Capability | jido_claw | Loomkin | Gap |
|-----------|-----------|---------|-----|
| Concurrency limits | Per-runner caps (20/10/10/10, 50 total) | Unlimited | Critical |
| Shell persistence | CWD + env preserved across calls | Reset each call | Critical |
| Output buffering | 50ms coalescing, 64KB chunks | Full collect, 10KB cap | Major |
| Session tracking | Registry with cleanup | None | Major |
| Container isolation | Sprite containers | Validation-based only | Minor |

**Recommendations:**
- **P0: RunnerRegistry** — Add a `Loomkin.Tools.RunnerRegistry` GenServer that tracks active tool executions per type and enforces configurable concurrency caps. Lowest risk, highest value.
- **P0: ShellSession** — Wrap shell tool calls in a `Loomkin.Tools.ShellSession` that preserves CWD and env vars per agent. Agents working on multi-step builds currently lose context between commands.
- **P1: OutputBuffer** — Stream tool output in 50ms/64KB chunks instead of collecting everything. Prevents UI stalls on long-running commands.
- **P2: Container isolation** — Defer. Loomkin's validation-based sandboxing is adequate for the current trust model (user-owned agents). Revisit if multi-tenant.

---

### 2. Reasoning Strategies — Loomkin-Native Approach

> **Key insight (2026-03-21):** Loomkin's multi-agent architecture already achieves what most
> single-agent reasoning strategies try to simulate. The kin *are* the reasoning strategies.
> Adopting jido_claw's strategy system wholesale would be redundant and misaligned with Loomkin's
> strengths. Instead, we adopt selectively where strategies complement — not duplicate — kin
> collaboration.

**What jido_claw does:**
- 8 pluggable strategies via Reasoning Strategies Registry
- Runtime switching: users can change strategy mid-session
- Complexity-aware routing: scores drive strategy selection
- Strategies: ReAct, CoT, CoD, ToT, GoT, AoT, TRM, Adaptive

**What Loomkin already solves natively via kin-to-kin collaboration:**

| jido_claw Strategy | Loomkin Equivalent (Multi-Agent) | Why Loomkin's is Better |
|-------------------|--------------------------------|------------------------|
| **ToT** (explore 3 approaches, pick best) | Spawn 3 researchers, each explores a path, lead synthesizes | *Actual* parallel exploration across separate contexts, not one LLM pretending to branch |
| **GoT** (merge partial reasoning into graph) | Decision graph captures this at team level across agents | Persistent, auditable, cross-session — not ephemeral single-pass reasoning |
| **TRM** (generate → critique → refine) | Coder → reviewer → coder loop | Real critique from a separate agent with different system prompt is stronger than self-critique |
| **Multi-perspective deliberation** | `spawn_conversation` with `design_review` or `red_team` templates (Epic 13) | Full multi-agent deliberation with persona-driven reasoning, not simulated perspectives |

**What Loomkin should adopt (complementary, not duplicative):**

| Capability | Action | Why | Effort |
|-----------|--------|-----|--------|
| **CoD for internal reasoning** | Use CoD-style concise prompting within the ReAct loop for non-tool deliberation steps | Saves tokens on "thinking about what to do next" without changing the tool loop | P1, 1 day |
| **Complexity scores as orchestration signals** | Emit `Jido.AI.Reasoning.Adaptive.Strategy.analyze_prompt/1` scores as telemetry; use high scores to trigger lead to spawn conversations or sub-teams | Complexity drives *orchestration decisions* (more kin), not *reasoning mode switches* (different prompts) | P1, 1 day |
| **Per-turn adaptive intelligence** | Within the ReAct loop, assess per-turn complexity to decide: direct tool call vs. pause-and-deliberate | Smarter ReAct, not a different strategy — the agent loop itself becomes complexity-aware | P2, 2 days |

**What we are NOT adopting and why:**

- **Per-session strategy switching** — Unnecessary. Loomkin agents use ReAct because they need tools. Non-tool strategies (CoT, ToT, GoT) produce a single LLM pass with no tool access — useless for agents that need to *do things*. When deeper reasoning is needed, spawn a conversation.
- **GoT/AoT/TRM as individual strategies** — These are single-agent approximations of what Loomkin does natively with multiple kin. Adding them would be a step backward from real multi-agent collaboration.
- **Strategy Registry / marketplace UI** — Over-engineering. The orchestration layer (lead/concierge deciding when to spawn sub-teams) is Loomkin's strategy selector.

**The Loomkin philosophy:** When a task is complex, don't make one agent think harder — give it more kin to think *with*.

---

### 3. Workflow Orchestration

**What jido_claw does:**
- WorkflowRun + WorkflowStep schemas (Ash Framework state machine)
- Each step has: status, attempt count, retry history, timestamps
- Approval gates integrated as workflow step dependencies
- Cron daemon with YAML persistence and auto-disable on failure
- FSM-based sequential execution with branching

**What Loomkin has:**
- Task system with dependencies (`:requires_output` edges, content-aware coupling)
- Agent-driven implicit workflows (no formal state machine)
- Approval as optional tool (not enforced at workflow level)
- MessageScheduler for delayed delivery (no cron)
- No retry lineage tracking

**Gap analysis:**

| Capability | jido_claw | Loomkin | Gap |
|-----------|-----------|---------|-----|
| Workflow state machine | WorkflowRun/Step schemas | Implicit via tasks | Major |
| Audit trail | Per-step timestamps + attempts | Task status only | Major |
| Retry lineage | Per-step attempt history | None | Major |
| Approval gates | Workflow dependency type | Optional tool | Minor |
| Cron scheduling | Persistent YAML daemon | None | Minor |
| FSM transitions | Explicit state machine | Agent autonomy | N/A (different philosophy) |

**Recommendations:**
- **P1: WorkflowRun/Step schemas** — Add lightweight Ecto schemas that record step-level execution history. Don't replace Loomkin's agent-driven model — augment it with an audit trail. This becomes the foundation for replay, dry-run, and compliance.
- **P1: Retry lineage** — Add `retry_history` (list of `{attempt, result, timestamp}`) to task schema. Cheap addition, huge observability win.
- **P2: Approval gates as task deps** — Add `:approval_required` as a dependency type in TaskDeps. The approval tool already exists; this just makes it enforced rather than optional.
- **P2: Cron daemon** — Extend MessageScheduler with persistent cron expressions. Useful for recurring health checks, report generation.
- **Skip FSM transitions** — Loomkin's agent autonomy is a strength. Formal FSMs would constrain the agent-driven model without clear benefit.

---

### 4. VFS, Solutions Engine & Security

#### Virtual Filesystem

**What jido_claw does:** Transparent `github://`, `s3://`, `git://` URI routing via VFS Resolver. Agents read/write files across backends with unified API.

**What Loomkin has:** Local filesystem only. Epic 12 (Vault Primitive) plans S3 support but isn't implemented yet.

**Recommendation (P2):** Build a `Loomkin.VFS.Resolver` behaviour with `local`, `github`, and `s3` adapters. Aligns with Epic 12 Vault work. Defer until Vault lands.

#### Solutions Engine

**What jido_claw does:** SHA-256 fingerprints of task descriptions → cached solutions with trust scoring (35% verification, 25% completeness, 25% freshness, 15% reputation). BM25-inspired search for finding similar past solutions.

**What Loomkin already has:** Context Keepers (persistent GenServers with relevance scoring, confidence tracking, staleness decay, smart/raw/synthesize retrieval), Decision Graph (queryable audit trail with confidence propagation), and Failure Memory (bootstraps lessons from past errors into agent loop). These cover ~80% of the value.

**Recommendation (P2):** Demoted from P0. The keeper + decision graph + failure memory system already provides rich knowledge reuse. The only gap is exact-match task fingerprinting — could be added as a lightweight check in `Tasks` before assignment without a whole new subsystem. Keepers already track `confidence`, `relevance_score`, `success_count`, `miss_count`.

#### Security

**What jido_claw does:**
- AES-256-GCM encryption at rest (Cloak library)
- Multi-layer secret redaction: logs, prompts, UI, PubSub
- HMAC-SHA256 webhook verification

**What Loomkin has:**
- Token encryption (Ecto-level)
- Password redaction via Ecto
- No systematic redaction across logs/prompts/PubSub
- No webhook verification

**Recommendations:**
- **P0: Multi-layer secret redaction** — Add a `Loomkin.Security.Redactor` that scrubs secrets from log output, LLM prompts, and PubSub messages. Prevents accidental secret leakage in agent communications.
- **P1: AES-256-GCM migration** — Switch from current token encryption to Cloak-based AES-256-GCM for all sensitive fields (API keys, tokens, credentials).
- **P1: HMAC webhook verification** — Add to any webhook endpoints for integrity verification.

---

### 5. Swarm Orchestration & Monitoring

**What jido_claw does:**
- First-class swarm tools: `spawn_agent`, `list_agents`, `send_to_agent`, `kill_agent`
- 6 agent templates (coder, reviewer, refactorer, etc.)
- Per-tenant supervision subtrees
- Heartbeat: `.jido/heartbeat.md` updated every 60s
- Swarm display: dual-mode (single agent / swarm grid) with per-agent metrics
- 20+ telemetry metrics
- 8 LLM providers, 35+ models

**What Loomkin has:**
- Superior team hierarchy (parent/child with depth tracking)
- Registry-based agent discovery
- 13+ signal types via Jido.Signal
- Rich per-agent metrics (cost, collaboration score, complexity)
- 15+ peer tools for agent-to-agent comms
- Dual model picker (thinking + fast) but limited provider count
- No swarm control tools exposed to agents
- No heartbeat system
- Metrics exist but not surfaced in unified dashboard

**Gap analysis:**

| Capability | jido_claw | Loomkin | Gap |
|-----------|-----------|---------|-----|
| Agent control tools | 4 first-class tools | None exposed | Major |
| Heartbeat monitoring | 60s interval, markdown file | None | Major |
| Swarm visualization | Dual-mode display | Per-agent cards (good but no grid) | Minor |
| LLM providers | 8 providers, 35+ models | 3 providers | Moderate |
| Team hierarchy | Flat swarm | Parent/child with depth | Loomkin wins |
| Cross-team messaging | send_to_agent only | 3 broadcast patterns + queries | Loomkin wins |
| Signal types | SignalBus (generic) | 13+ domain-specific signals | Loomkin wins |

**Recommendations:**
- **P1: Swarm control tools** — Add `list_agents` and `kill_agent` as agent tools. Loomkin already has the registry; just expose it. Agents should be able to inspect and manage their peers.
- **P1: Heartbeat system** — Add a `Loomkin.Heartbeat` GenServer that periodically writes system health to ETS/PubSub. Feed into WorkspaceLive for at-a-glance monitoring.
- **P2: Additional LLM providers** — Add OpenRouter as a meta-provider (gives access to dozens of models through one integration). Lower priority since dual-model picker covers most use cases.

---

## Implementation Roadmap

### Phase 1: Quick Wins (Week 1-2)
- Runner concurrency limits (2d)
- Multi-layer secret redaction (2d)
- Complexity scores as orchestration signals (1d)
- CoD for internal ReAct deliberation (1d)
- Heartbeat system (1d)

**Impact:** Prevents runaway tool execution, closes security gap, makes agent loop complexity-aware for smarter orchestration decisions.

### Phase 2: High-Value Features (Week 3-4)
- Solutions Engine with fingerprinting + trust scoring (3d)
- Persistent shell sessions (3d)
- Swarm control tools (2d)
- Retry lineage tracking (2d)

**Impact:** Dramatically reduces token spend via caching, improves developer experience with persistent shells.

### Phase 3: Architecture (Week 5-7)
- WorkflowRun/Step audit trail (5d)
- Output coalescing (2d)
- Approval gates as task deps (3d)

**Impact:** Adds formal audit trail, improves streaming UX.

### Phase 4: Future (Week 8+)
- Virtual Filesystem (align with Epic 12 Vault) (4d)
- Cron scheduling daemon (3d)
- Additional LLM providers (3d)
- Container isolation (if going multi-tenant)

---

## What Loomkin Already Does Better

Worth noting — jido_claw lacks several things Loomkin has:

| Feature | Loomkin | jido_claw |
|---------|---------|-----------|
| Team hierarchy | Parent/child with depth tracking | Flat swarm |
| Cross-team messaging | 3 patterns + QueryRouter | Single send_to_agent |
| Conversation agents | Multi-agent deliberation (13 signal types) | None |
| Decision graph | Design evolution audit trail | None |
| Speculative execution | Tentative states + assumption tracking | None |
| Task dependencies | Content-aware coupling, `:requires_output` | Basic sequential |
| Agent negotiation | Counter-proposals + timeout auto-accept | None |
| Partial task results | Pipeline unblocking with intermediate data | None |

Loomkin's agent autonomy model and team coordination are significantly more advanced. The adoption opportunities are primarily in **infrastructure** (sandboxing, caching, security) rather than **orchestration** (where Loomkin leads).

---

## Decision Points for Brandon

1. **Solutions Engine** — Biggest bang-for-buck. Should this be workspace-scoped (shared across teams) or team-scoped?
2. **Shell persistence** — Per-agent or per-team? Agents in the same team may want shared shell state.
3. **Complexity-driven orchestration** — Should high complexity scores automatically trigger the lead to spawn a conversation, or just surface as a hint in telemetry?
4. **Workflow audit trail** — Lightweight logging or full Ash state machine? Former is simpler and fits Loomkin's philosophy better.
5. **VFS timing** — Build standalone or bundle with Epic 12 Vault?
