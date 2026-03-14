# Spec-Aware Agents: Verification-Gated Task Completion

> Agents that know what must remain true — and prove it before calling a task done.

## Origin

Inspired by [Spec Led Development](https://specled.dev/), a methodology that maintains
alignment between intent, code, tests, and documentation through a verification loop.
The core insight: **"Software changes faster than shared understanding."** When agents
enter the picture, this drift accelerates. Specled's answer is a minimal contract layer
(`.spec/specs/*.spec.md`) plus a verification loop that proves implementation matches
intent.

This doc explores what Loomkin should take from that idea — filtered through our own
values and architecture. The goal is not to adopt Specled wholesale, but to ask: **what
would it mean for Loomkin agents to understand intent, not just instructions?**

---

## The Problem

### Task Completion is Self-Reported

Today, when an agent finishes work, it calls `peer_complete_task` with a result string,
actions taken, files changed, and decisions made. The manager trusts this report. There
is no automated verification that the agent actually achieved what was intended — only
that the agent *believes* it did.

For quick tasks this is fine. For long-horizon work — campaign-tier tasks spanning
dozens of files across multiple agents — self-reported completion is a liability.
An agent can confidently declare success while introducing a subtle regression, violating
an architectural invariant, or solving the wrong problem entirely.

### Intent Lives in Natural Language

Task descriptions are prose. Good prose, sometimes — but prose that an LLM interprets
through its own context window, system prompt, and whatever it happened to read. There
is no structured way to say "this task is done when X, Y, and Z are provably true."

The decision graph captures *what happened* and *why*. Context keepers store the full
conversation. But neither captures *what must remain true* as a durable, verifiable
contract. That's the gap.

### Drift Compounds Silently

When Agent A completes a task and Agent B starts downstream work, B inherits A's
`predecessor_outputs` — a snapshot of A's result. If A's work subtly violated an
invariant, B builds on a broken foundation. The speculative execution system makes this
worse: tentative completions propagate assumptions that may be wrong in ways nobody
checks.

---

## What Loomkin Should Take from Specled

Not the methodology. Not the tooling. The **mental model**.

Specled's portable core has five claim types: Subject, Requirement, Scenario,
Verification, Exception. Strip away the spec files and the CLI and what remains is a
simple idea: for any piece of work, you should be able to state what must be true, show
a concrete scenario, point at evidence, and note approved deviations.

Loomkin already has the bones for this:

| Specled concept | Loomkin equivalent | Gap |
|---|---|---|
| Subject | Task (title + description) | None — tasks identify what's being worked on |
| Requirement | — | **Missing.** No structured "what must stay true" |
| Scenario | — | **Missing.** No concrete success criteria beyond prose |
| Verification | — | **Missing.** No automated proof that work satisfies intent |
| Exception | `open_questions` on task | Partial — captures unknowns but not approved deviations |

The proposal: add structured requirements, success criteria, and verification commands
to the task schema. Not as a separate spec system — as a natural extension of what tasks
already track.

---

## Design Principles

1. **Tasks are the contract, not files.** Loomkin's unit of work is the task. Adding a
   parallel `.spec/` directory would split the source of truth. Instead, embed
   verification into the task lifecycle where agents already operate.

2. **Verification is evidence, not ceremony.** A verification step should be a shell
   command, a test path, or a function call — something that returns pass/fail. Not a
   document to maintain. The cheapest useful check.

3. **Progressive, not mandatory.** Simple tasks don't need verification gates. The
   system activates heavier machinery as scope grows — consistent with automatic
   scope detection (Quick → Session → Campaign).

4. **The BEAM makes this cheap.** Verification runs as a supervised task alongside the
   agent loop. If it crashes, the agent isn't affected. If it times out, the task stays
   in review. OTP's process isolation means verification is zero-risk to the running
   system.

5. **Trust the decision graph.** Verification results flow into the decision graph as
   `:observation` nodes with concrete confidence scores. A verified task contributes
   high-confidence nodes. An unverified task contributes low-confidence nodes. Cascade
   propagation does the rest — downstream tasks automatically inherit appropriate
   confidence levels.

---

## Architecture

### Task Schema Extension

```
TeamTask (existing)
├── title, description, status, owner, priority
├── result, actions_taken, discoveries, files_changed
├── decisions_made, open_questions
│
├── requirements        [String]     # "what must remain true"
├── success_criteria    [String]     # concrete, testable conditions
├── verification_cmd    String       # shell command that returns 0 on success
├── verification_status Enum         # :pending | :passed | :failed | :skipped
├── verification_output String       # stdout/stderr from last run
└── verification_ran_at DateTime     # when verification last executed
```

**Why on the task, not a separate table:** tasks already carry `actions_taken`,
`discoveries`, `files_changed`, `decisions_made`, `open_questions`. Requirements and
verification are the same kind of structured metadata — they describe the work, not
a parallel system.

### Verification Flow

```
Agent calls peer_complete_task
    │
    ├─ [no verification_cmd] ──→ status: :completed (today's behavior, unchanged)
    │
    └─ [has verification_cmd] ──→ status: :ready_for_review
                                      │
                                Task.Supervisor.async_nolink
                                      │
                                Run verification_cmd in project_path
                                      │
                              ┌───────┴───────┐
                              │               │
                          exit 0          exit non-zero
                              │               │
                     verification_status   verification_status
                        = :passed            = :failed
                              │               │
                     status: :completed    status: :in_progress
                              │               │
                     emit :task_verified    emit :task_verification_failed
                     signal (high conf)    signal (include output)
                              │               │
                     decision graph:        agent receives failure
                     :observation node     context + output, retries
                     confidence: 0.9+
```

### How Agents Use This

#### Creating tasks with verification

The lead agent (or any agent creating subtasks) can optionally include requirements
and a verification command when decomposing work:

```
peer_create_task(
  title: "add rate limiting to /api/sessions",
  description: "...",
  requirements: [
    "requests exceeding 10/min per ip return 429",
    "rate limit state does not persist across deploys"
  ],
  success_criteria: [
    "mix test test/loomkin_web/rate_limit_test.exs passes",
    "no new compile warnings introduced"
  ],
  verification_cmd: "mix test test/loomkin_web/rate_limit_test.exs --max-failures 1"
)
```

The coder agent sees these requirements in its task context alongside the description.
It knows what "done" looks like before writing a line of code.

#### Completing tasks with verification

When the coder calls `peer_complete_task`, the system checks for a `verification_cmd`.
If present, the task moves to `:ready_for_review` and verification runs asynchronously.
The agent doesn't block — it can pick up the next task. If verification fails, the agent
receives the failure output as a new message and can retry.

#### Verification failure loop

```
Verification fails (exit non-zero)
    │
    ├─ Attempt 1: agent receives output, task returns to :in_progress
    │              agent reads output, fixes, re-completes
    │
    ├─ Attempt 2: same flow
    │
    └─ Attempt 3+: task escalates to lead agent
                   lead can: reassign, adjust requirements, mark exception
```

Max retry count is configurable per task (default: 2). This prevents infinite loops
while giving agents a fair chance to self-correct.

### Decision Graph Integration

Verification results produce decision graph nodes automatically via AutoLogger:

| Signal | Node type | Confidence | Metadata |
|---|---|---|---|
| `:task_verified` | `:observation` | 0.95 | `{task_id, cmd, output}` |
| `:task_verification_failed` | `:observation` | 0.3 | `{task_id, cmd, output, attempt}` |
| `:task_verification_skipped` | `:observation` | 0.6 | `{task_id, reason}` |

Cascade propagation means: if a verified task feeds into a downstream task via
`:requires_output`, the downstream task's decision nodes inherit high confidence from
the verified predecessor. If the predecessor failed verification, downstream confidence
drops — and the lead agent can see this in the graph before the downstream agent wastes
work on a shaky foundation.

This is where verification pays for itself in long-horizon work. A campaign with 20
tasks and 5 agents doesn't need a human reviewing each completion. The confidence
cascade surfaces problems automatically.

---

## What This Enables

### Long-Horizon Coding (Epic 16)

Campaign-tier tasks get concrete quality gates. A user who kicks off an overnight
refactoring can check the decision graph in the morning and see which tasks passed
verification vs. which ones the agents struggled with. Trust through transparency —
not "the agent said it's done" but "the tests pass and here's the proof."

### Speculative Execution (landed)

Speculative tasks can include verification. If a tentative completion passes
verification, confidence in the speculation rises. If it fails, the system has a
concrete signal to discard the speculative work — not just assumption mismatch, but
provable failure. This infrastructure is already merged and waiting for this signal.

### Self-Healing Teams (landed)

When verification fails, the diagnostician agent already has a healing pipeline to
work with. Adding structured context — the requirements, success criteria, verification
command, and its output — gives the diagnostician dramatically better input than "the
agent said it completed the task but something seems wrong." Verification failure
becomes a first-class healing trigger.

### Decision Graph Nervous System

Verification observations are high-value graph nodes. They're concrete (pass/fail),
timestamped, and reproducible. This is exactly the kind of structured signal the
nervous system needs — not just "agent decided X" but "the system proved X is true."

---

## Scope & Non-Goals

**In scope:**
- Task schema fields for requirements, success criteria, verification
- Async verification runner (supervised task)
- Verification status lifecycle (pending → passed/failed/skipped)
- AutoLogger signals for decision graph integration
- Retry + escalation flow for failed verification
- Tool updates: `peer_create_task` and `peer_complete_task` accept new fields

**Not in scope:**
- Separate `.spec/` file system (tasks are the contract)
- Spec authoring CLI or mix tasks (agents author verification inline)
- CI integration (loomkin is runtime, not a CI tool)
- Mandatory verification on all tasks (progressive activation only)
- Human-facing spec review UI (decision graph already surfaces this)

---

## Risks & Open Questions

1. **Verification command security.** Agents would be constructing shell commands that
   run in the project directory. This needs the same sandboxing as existing file/shell
   tools — `project_path` scoping, no escape to parent directories. The existing
   permission system (`check_permission` callback) applies here.

2. **What counts as a good verification command?** For Elixir projects, `mix test
   path/to/test.exs` is obvious. For other types of work (documentation, architecture
   decisions, config changes), verification is less clear. The system should allow
   `:skipped` as a valid status — not everything is automatable. The lead agent decides
   whether a task warrants a verification command.

3. **Verification latency.** Test suites can be slow. The async design means agents
   don't block, but a 5-minute test suite means 5 minutes before the task graph updates.
   For campaign-tier work this is acceptable. For quick-tier work, verification should
   be fast or skipped.

4. **Over-specification risk.** If agents start writing overly narrow requirements and
   brittle verification commands, this becomes a drag instead of a quality gate. The
   system prompt guidance should emphasize: requirements describe invariants, not
   implementation details. "Users can log in" not "the login function returns {:ok, user}."

5. **Bootstrapping.** Early on, most tasks won't have verification commands. That's
   fine — the system degrades gracefully to today's behavior. As agents learn which
   tasks benefit from verification (and which verification commands work), the quality
   of verification improves organically.

---

## Relationship to Specled

This proposal is influenced by Specled's thinking but diverges deliberately:

| Specled | Loomkin's approach |
|---|---|
| Spec files live alongside code (`.spec/`) | Verification lives on the task — agents' native unit of work |
| Human authors specs | Agents author requirements + verification as part of task decomposition |
| CLI tooling runs verification | Supervised OTP task runs verification within the BEAM |
| CI enforces the loop | The agent mesh enforces the loop in real-time |
| Language-agnostic portable model | BEAM-native, exploits process isolation and supervision |
| Spec drift is the enemy | Task completion without evidence is the enemy |

The philosophical alignment is strong: both systems believe that **intent without
verification is just hope**. The implementation diverges because Loomkin is a runtime
agent orchestrator, not a development methodology. Loomkin's verification loop runs
inside the agent mesh, not alongside it.

---

## Implementation Path

This naturally decomposes into existing task-sized work:

1. **Schema extension** — Add fields to `TeamTask`, migration, changeset updates
2. **Verification runner** — Supervised async task, sandbox, timeout handling
3. **Task lifecycle update** — Wire verification into completion flow, retry logic
4. **Tool updates** — `peer_create_task` and `peer_complete_task` accept new fields
5. **AutoLogger signals** — New signal types, decision graph node creation
6. **System prompt guidance** — Teach agents when and how to write good requirements
7. **Escalation flow** — Failed verification → retry → lead notification

Dependencies: none. This builds entirely on existing infrastructure (tasks, signals,
decision graph, tool system). It can be adopted incrementally — tasks without
verification commands behave exactly as they do today.
