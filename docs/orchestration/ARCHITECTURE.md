# Loomkin Orchestration — Architecture

`Loomkin.Orchestration` is a hardened 9-phase agent pipeline implemented in native Elixir/OTP. It runs as a first-class supervised subtree of `Loomkin.Application`, not as a CLI plugin.

## Front door: every user message enters through the orchestrator

Loomkin has exactly one seam where a user-initiated task enters the runtime: `Loomkin.Session.handle_call({:send_message, text, opts}, _from, state)` in `lib/loomkin/session/session.ex`. Every chat, every coding request, every tool call flows through that callback. The orchestration framework owns it.

```
Client (CLI or LiveView)
  └─► SessionChannel.handle_in("send_message")
        └─► Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor)
              └─► Loomkin.Session.send_message/3
                    └─► Loomkin.Session GenServer.handle_call({:send_message, text, opts})
                          │
                          ▼
                    Loomkin.Orchestration.SessionBridge.dispatch(state, text, opts)
                          │
                          ├─► IntentClassifier.classify(text, context)
                          │     • rule-first  (greetings, length, code-fence, action verbs)
                          │     • LLM fallback  (small fast model) only on :ambiguous
                          │
                          ├─► :fast_chat    → Pipelines.LitePipeline.run/2
                          │                   (spawn or reuse a Teams.Agent;
                          │                    streaming signals byte-for-byte identical
                          │                    to today)
                          │
                          ├─► :tool_use     → Pipelines.ShortPipeline.run/2
                          │                   (implement → validate → commit;
                          │                    no review gates)
                          │
                          └─► :complex_task → SwarmCoordinator.submit
                                              + IssueOrchestrator (full 9 phases)
                                                └─► Executor → WorkUnitPipeline
                                                      • implementer = Workers.TeamsCoder
                                                          → Teams.Manager.spawn_agent
                                                          → Teams.Agent runs Loomkin.AgentLoop
                                                          → tool calls via Loomkin.Tools.Registry.execute/4
                                                      • validator   = Validators.Composite
                                                          → mix test / mix format / mix compile
                                                                                                in the epic's worktree
                                                      • reviewer    = Gates.AdversarialReviewGate
                                                      • committer   = Committers.Git
                                                                                                (real git_cli commit)
                          │
                          ▼ (all paths)
                    Loomkin.Orchestration.SignalBridge
                          (orchestration.* topics → Loomkin.Signals.publish/1
                                                                            with new type session.orchestration.phase)
                          │
                          ▼
                    SessionChannel.handle_info(%Jido.Signal{…})
                          → push(socket, "stream_token" | "new_message"
                                       | "orchestration_phase" | "session_status" | ...)
```

### Why hard-cutover instead of feature-flag

Every code path eventually goes through `SessionBridge.dispatch/3`. There is no `:legacy` route left in production. The fast-path (`LitePipeline.run/2`) exists to preserve the exact streaming-signal contract for conversational messages so existing UI never notices the new layer. Complex tasks pay for the extra gates because they should.

### Streaming contract (preserved verbatim)

| Signal type                          | Producer                       | Consumer                        |
| ------------------------------------ | ------------------------------ | ------------------------------- |
| `session.message.new`                | Session / LitePipeline         | SessionChannel → `new_message`  |
| `session.status.changed`             | Session / LitePipeline         | SessionChannel → `stream_*`     |
| `agent.stream.*`                     | Teams.Agent / LitePipeline     | SessionChannel → `stream_token` |
| `session.permission.request`         | Permissions Manager            | SessionChannel → permission UI  |
| `team.ask_user.question`             | Teams.Agent                    | SessionChannel → ask-user UI    |
| `session.orchestration.phase`  *NEW* | SignalBridge                   | SessionChannel → `orchestration_phase` |

CLI and LiveView consume the new `orchestration_phase` event for inline phase progress. Every other signal keeps its exact prior shape and timing.

## What we ported, and why

| Capability | Loomkin equivalent | Why this shape |
| --- | --- | --- |
| 9-phase workflow | `IssueOrchestrator` (`gen_statem`) with named states + transition guards | The state machine *is* the invariant. You cannot transition without the prior phase's artifact. |
| 4-phase per-work-unit loop (IMPLEMENT → VALIDATE → ADVERSARIAL REVIEW → COMMIT) | `WorkUnitPipeline` (`gen_statem`) | Orchestrator validates independently between IMPLEMENT and VALIDATE. Never trust subagent self-reports. |
| Binary PASS/FAIL adversarial review | `Loomkin.Orchestration.Gates.AdversarialReviewGate` | Rejects any verdict without `file:line` evidence. No "approved with comments." |
| 3-iteration cap then escalate | `IssueOrchestrator` state guard + `:human_escalation` signal on the bus | A bus signal is observable; LiveView surfaces it; humans don't have to poll. |
| Recursive orchestration | `SwarmCoordinator` → `EpicSupervisor` (DynamicSupervisor) → `IssueOrchestrator` → `WorkUnitSupervisor` → `WorkUnitPipeline` | One supervisor per scope. Failure of one epic cannot kill another. |
| Worktree per epic | `Worktree` GenServer wrapping `git_cli` | True FS isolation; cleanup in `terminate/2`; supervisor `restart: :transient`. |
| Knowledge base (JSONL) | Ecto-backed `KnowledgeFact` + `Importer`/`Exporter` for JSONL compatibility | Queryable, transactional, browseable in LiveView; JSONL stays an escape hatch. |
| Knowledge priming | `Primer.prime/2` ranks by recency × confidence × tag overlap | Mirrors a knowledge-priming workflow without external tooling dependencies. |
| Knowledge curation | `Curator` GenServer subscribes to `orchestration.work_unit.completed` | Curator-extracted facts persist at `confidence: medium` until validated. |
| Quality rubrics | `Loomkin.Orchestration.Reviewers.*` behaviours + scored prompts | Rubrics are code, not just docs. |
| PR shepherd | `PRShepherd.Server` GenServer per open PR | One process per PR; isolated failures; restart policy. |
| Self-reflection | `Curator` triggered at closure | Extraction is automatic, not a manual command. |

## Supervision tree

```
Loomkin.Application
└── Loomkin.Orchestration.Supervisor                (rest_for_one)
    ├── Loomkin.Orchestration.KnowledgeStore        (GenServer + Ecto)
    ├── Registry: Loomkin.Orchestration.EpicRegistry
    ├── Registry: Loomkin.Orchestration.WorkUnitRegistry
    ├── Registry: Loomkin.Orchestration.ShepherdRegistry
    ├── Task.Supervisor: Loomkin.Orchestration.ReviewGate.Supervisor
    ├── Loomkin.Orchestration.SwarmCoordinator      (GenServer, singleton)
    ├── Loomkin.Orchestration.EpicSupervisor        (DynamicSupervisor)
    │   └── (per epic) IssueOrchestrator (gen_statem)
    │       ├── Worktree (GenServer)
    │       └── Loomkin.Orchestration.WorkUnitSupervisor (DynamicSupervisor)
    │           └── (per work unit) WorkUnitPipeline (gen_statem)
    ├── Loomkin.Orchestration.PRShepherd.Supervisor (DynamicSupervisor)
    │   └── (per PR) PRShepherd.Server (GenServer)
    └── Loomkin.Orchestration.Curator               (GenServer)
```

## Signal topics (`Jido.Signal.Bus` / `Phoenix.PubSub`)

| Topic | Emitted by | Consumed by |
| --- | --- | --- |
| `orchestration.epic.created`           | `SwarmCoordinator` | LiveView, telemetry |
| `orchestration.epic.phase_entered`     | `IssueOrchestrator` | LiveView, telemetry |
| `orchestration.epic.escalated`         | `IssueOrchestrator` | LiveView (red banner) |
| `orchestration.work_unit.started`      | `WorkUnitPipeline` | LiveView |
| `orchestration.work_unit.completed`    | `WorkUnitPipeline` | `Curator`, LiveView |
| `orchestration.gate.opened`            | `Gate` modules | LiveView |
| `orchestration.gate.verdict`           | `Gate` modules | `IssueOrchestrator`, LiveView |
| `orchestration.knowledge.fact_added`   | `KnowledgeStore` | LiveView (knowledge browser) |

## The 9 phases

```
1. research        — Researcher worker gathers context (BEADS prime + repo intel)
2. plan            — Planner produces an implementation plan with work units + DoD
3. plan_review     — PlanReviewGate (3 reviewers: feasibility, completeness, scope)
4. design_review   — DesignReviewGate (5 reviewers: PM, architect, designer, security, CTO)
5. decompose       — Plan committed to WorkUnit rows with dependency graph
6. execute         — One WorkUnitPipeline per WorkUnit; runs in topological order
7. final_review    — Cross-unit AdversarialReviewGate against the whole epic DoD
8. pr              — PR opened; PRShepherd takes over
9. closure         — Curator extracts knowledge; epic closes
```

Each phase has a single named state in `IssueOrchestrator`. Transitions require both:
- the prior phase's artifact persisted to Postgres, and
- the prior phase's gate verdict = `:pass` (if a gate guards the boundary).

## The 4-phase work unit pipeline

```
implement → validate → adversarial_review → commit
```

- **implement**: Coder worker writes code in the epic's worktree.
- **validate**: `IssueOrchestrator` *itself* runs the validators (tests, type checker, lint) — does not ask the Coder if it passed. This is the trust-nothing principle.
- **adversarial_review**: `AdversarialReviewGate` runs DoD verifier against the work unit's DoD. Every verdict must cite `file:line`. Binary PASS/FAIL.
- **commit**: On PASS, commit to the worktree branch with a message including the work unit ID and the verdict trace.

## Cross-model review

A reviewer is invoked with `model:` from per-reviewer config. When `cross_model: true`, the reviewer model must differ from the writer model (enforced at gate-config validation time). Models flow through `req_llm`'s 16-provider client.

## Trust-nothing invariants (enforced in code, not just docs)

1. `IssueOrchestrator` reads gate verdicts from the bus — never from the worker that produced the work.
2. `AdversarialReviewGate` rejects any verdict whose `evidence` list is empty or fails the `file:line` regex.
3. `WorkUnitPipeline` runs validators in-process, not via the Coder worker.
4. `Curator` only writes facts at `confidence: medium`; promotion to `:high` requires either human or repeat-agreement.

## File layout

See `loomkin-server/lib/loomkin/orchestration/` per the plan module map.

## Glossary

- **Epic** — a unit of work tracked across all 9 phases.
- **Work Unit** — a sub-unit of an epic; runs the 4-phase pipeline once.
- **DoD item** — Definition-of-Done item; a single verifiable acceptance criterion.
- **Verdict** — a `:pass | :fail` decision with evidence + blocking/warning lists.
- **Gate** — a group of reviewers that all must pass before phase advances.
- **Reviewer** — a single LLM-backed evaluator implementing the `Reviewer` behaviour.
