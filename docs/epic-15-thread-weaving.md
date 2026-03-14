# Epic 15: Orchestrator Mode & Structured Task Handoffs

## Problem Statement

Loomkin agents communicate via PubSub message passing and store task results as plain strings (`task.result`). This creates two problems:

1. **Lossy handoffs**: Task results are unstructured strings. When Agent B depends on Agent A's work via `:requires_output`, it receives `"  - #{title}: #{result}"` — no structured understanding of what was done, what was learned, what files changed, or what remains open.
2. **Orchestrators get pulled into tactics**: Lead agents have the full tool set (`@all_tools` — file operations, shell, git, LSP). Nothing architecturally prevents a Lead from writing code instead of delegating, which defeats the purpose of team decomposition.

### What this epic does NOT do

This epic was originally inspired by Random Labs' [Slate architecture](https://randomlabs.ai/blog/slate) and its "Thread Weaving" pattern — where compressed "episodes" are injected into dependent agents' context windows. After analysis, **we rejected the episode injection approach** because it competes with Loomkin's core architectural advantage: distributed, pull-based context.

Loomkin agents avoid context compaction by keeping knowledge distributed across context keepers, the decision graph, ETS tables, and the query router. Agents pull what they need, when they need it. Injecting compressed episodes into the system prompt is push-based context compaction — exactly what the competition does, just better structured. Our existing tools (`context_retrieve`, `search_keepers`, `cross_team_query`) already solve the "how do I learn about prior work" problem without polluting the context window.

Instead, this epic:
- **Enriches task results** with structured fields so handoff messages carry more signal
- **Enforces orchestrator mode** so Leads delegate instead of doing tactical work
- Preserves the pull-based context model by making structured results available via existing retrieval patterns

## Dependencies

**No new deps required.** This builds entirely on existing infrastructure:
- Ecto schemas (task system)
- Role tool configuration (`role.ex`)
- Agent task completion flow (`agent.ex`, `tasks.ex`)

---

## 15.1: Structured Task Results

**Complexity**: Medium
**Dependencies**: None
**Description**: Add structured fields to `TeamTask` so completed tasks carry richer context than a flat result string. No separate schema, no LLM compression calls — agents populate these fields directly when completing tasks.

**Files to modify**:
- `lib/loomkin/schemas/team_task.ex` — Add structured result fields
- `lib/loomkin/teams/tasks.ex` — Accept structured fields in completion functions
- `lib/loomkin/tools/peer_complete_task.ex` — Accept structured fields in tool params

**New fields on `team_tasks`**:
```elixir
field :actions_taken, {:array, :string}, default: []
field :discoveries, {:array, :string}, default: []
field :files_changed, {:array, :string}, default: []
field :decisions_made, {:array, :string}, default: []
field :open_questions, {:array, :string}, default: []
```

These complement the existing `result` (summary) and `partial_results` fields. Agents populate them at completion time — no extra LLM call needed since the agent already knows what it did.

**Migration**:
```elixir
alter table(:team_tasks) do
  add :actions_taken, {:array, :text}, default: []
  add :discoveries, {:array, :text}, default: []
  add :files_changed, {:array, :text}, default: []
  add :decisions_made, {:array, :text}, default: []
  add :open_questions, {:array, :text}, default: []
end
```

**`peer_complete_task` tool changes**:
Add optional structured params so agents can report what they did:
```elixir
params do
  param :task_id, [type: :string, required: true]
  param :result, [type: :string, required: true, doc: "Summary of what was accomplished"]
  param :actions_taken, [type: {:array, :string}, doc: "Concrete actions taken"]
  param :discoveries, [type: {:array, :string}, doc: "Things learned during the task"]
  param :files_changed, [type: {:array, :string}, doc: "File paths created or modified"]
  param :decisions_made, [type: {:array, :string}, doc: "Choices made and brief rationale"]
  param :open_questions, [type: {:array, :string}, doc: "Unresolved issues for successor tasks"]
end
```

**Acceptance Criteria**:
- [ ] Structured fields added to `TeamTask` schema
- [ ] `peer_complete_task` accepts optional structured fields
- [ ] `mark_complete/3` persists structured fields alongside `result`
- [ ] Existing tests pass without modification (all new fields have defaults)
- [ ] Agents can still complete tasks with just `result` (backward compatible)

---

## 15.2: Enriched Predecessor Handoffs

**Complexity**: Medium
**Dependencies**: 15.1
**Description**: Enrich the predecessor output messages that dependent agents receive when tasks unblock. Currently `agent.ex:2192-2219` formats predecessor outputs as `"  - #{title}: #{result}"`. With structured fields available, handoff messages carry actionable detail.

**Files to modify**:
- `lib/loomkin/teams/tasks.ex` — `get_predecessor_outputs/1` returns structured fields
- `lib/loomkin/teams/agent.ex` — Format richer handoff messages in `:tasks_unblocked` handler

**Updated `get_predecessor_outputs/1`**:
```elixir
def get_predecessor_outputs(task_id) do
  # Existing query, but select structured fields too
  from d in TeamTaskDep,
    join: dep in TeamTask, on: d.depends_on_id == dep.id,
    where: d.task_id == ^task_id and d.dep_type == :requires_output and dep.status == :completed,
    select: %{
      task_id: dep.id,
      title: dep.title,
      result: dep.result,
      actions_taken: dep.actions_taken,
      discoveries: dep.discoveries,
      files_changed: dep.files_changed,
      decisions_made: dep.decisions_made,
      open_questions: dep.open_questions
    }
end
```

**Updated handoff message format** (in `handle_info({:tasks_unblocked, ...})`):
```
[System] Tasks now available: task_abc123. Use team_progress to see details.

Predecessor work summary:
### Task: "implement user auth" (by coder-1)
Result: Implemented JWT-based auth with refresh tokens
Files changed: lib/auth.ex, lib/auth/token.ex, lib/auth/plug.ex
Decisions: Used JWT over session tokens for statelessness
Discoveries: Phoenix 1.8 has built-in token verification
Open questions: Refresh token rotation strategy TBD
```

This gives the dependent agent structured context about prior work **in the handoff message itself** — no system prompt injection, no context window zone, no extra LLM calls. The agent can then use `context_retrieve` or `search_keepers` if it needs deeper detail, preserving the pull-based model.

**Acceptance Criteria**:
- [ ] `get_predecessor_outputs/1` returns structured fields when available
- [ ] Handoff messages include structured sections (files, decisions, discoveries, open questions)
- [ ] Empty structured fields are omitted from the message (no noise)
- [ ] Falls back gracefully for tasks completed before migration (fields are `[]`)
- [ ] Existing `:tasks_unblocked` handler tests updated

---

## 15.3: Orchestrator Mode for Lead Agents

**Complexity**: Medium
**Dependencies**: None (can be implemented in parallel with 15.1-15.2)
**Description**: When a Lead agent is managing a team with specialists, restrict its tool set to coordination-only tools. This enforces the strategy/tactics separation — the Lead dispatches and coordinates, specialists execute.

**Files to modify**:
- `lib/loomkin/teams/role.ex` — Add orchestrator tool set, mode detection
- `lib/loomkin/teams/agent.ex` — Apply tool restriction when orchestrator mode activates

**Orchestrator tool set**:
```elixir
@orchestrator_tools [
  # Team management
  Loomkin.Tools.TeamSpawn,
  Loomkin.Tools.TeamAssign,
  Loomkin.Tools.TeamSmartAssign,
  Loomkin.Tools.TeamProgress,
  Loomkin.Tools.TeamDissolve,
  # Peer communication
  Loomkin.Tools.PeerMessage,
  Loomkin.Tools.PeerCreateTask,
  Loomkin.Tools.PeerCompleteTask,
  # Context & knowledge
  Loomkin.Tools.ContextRetrieve,
  Loomkin.Tools.SearchKeepers,
  Loomkin.Tools.DecisionLog,
  Loomkin.Tools.DecisionQuery,
  # Cross-team
  Loomkin.Tools.ListTeams,
  Loomkin.Tools.CrossTeamQuery,
  Loomkin.Tools.CollectiveDecision,
  # Conversations
  Loomkin.Tools.SpawnConversation,
  # Read-only observation (can look, can't touch)
  Loomkin.Tools.FileRead,
  Loomkin.Tools.FileSearch,
  Loomkin.Tools.ContentSearch,
  Loomkin.Tools.DirectoryList,
  # User escalation
  Loomkin.Tools.AskUser
]
```

**What's removed** (vs `@all_tools`):
- `FileWrite`, `FileEdit` — no direct code changes
- `Shell` — no command execution
- `Git` — no direct git operations
- `LspDiagnostics` — diagnostic work is for specialists
- `SubAgent` — use `TeamSpawn` instead for proper team hierarchy

**Activation logic**:
```elixir
def resolve_tools_for_role(:lead, team_id) do
  if has_specialists?(team_id) do
    @orchestrator_tools
  else
    @all_tools  # Solo lead keeps full tool set
  end
end
```

The mode activates automatically when the Lead's team has at least one specialist agent. A solo Lead (no team yet, or team dissolved) retains full tools — it needs to bootstrap before it can delegate.

**System prompt addition** (when orchestrator mode active):
```
You are operating in orchestrator mode. Your team has specialists who handle implementation.
Your job is to:
- Break work into bounded tasks and assign them to the right specialist
- Monitor progress via team_progress and peer messages
- Make strategic decisions about approach and priorities
- Compose results from completed work into next steps
- Escalate to the user when decisions require human judgment

You can READ files to understand the codebase, but you cannot EDIT files, run commands, or make direct changes.
Delegate all implementation work to your team members.
```

**Acceptance Criteria**:
- [ ] Lead agents with specialists get orchestrator tool set (no write/shell/git)
- [ ] Solo Lead agents retain full tool set
- [ ] Tool set updates dynamically when specialists join/leave
- [ ] System prompt reflects orchestrator mode
- [ ] Lead can still read files for context (read-only observation)
- [ ] Configurable: `.loomkin.toml` can set `orchestrator_mode = false` to disable

---

## 15.4: Testing

**Complexity**: Medium
**Dependencies**: 15.1-15.3
**Description**: Test suite for structured task results and orchestrator mode.

**Files to create**:
- `test/loomkin/teams/structured_results_test.exs`
- `test/loomkin/teams/orchestrator_mode_test.exs`

**Testing strategy**:

- **Structured task results**: Complete tasks with structured fields via `peer_complete_task`. Verify fields persisted to database. Verify backward compatibility (tasks without structured fields still work).
- **Enriched handoffs**: Create tasks with `:requires_output` dependencies. Complete predecessor with structured fields. Verify dependent agent's `:tasks_unblocked` message includes structured sections. Verify empty fields are omitted.
- **Orchestrator mode**: Verify Lead with specialists gets restricted tool set. Verify solo Lead gets full tool set. Verify dynamic tool update when specialists join/leave. Verify `.loomkin.toml` override works.
- **Failure resilience**: Verify tasks without structured fields produce clean handoff messages. Verify orchestrator mode doesn't break when team state changes mid-task.

**Acceptance Criteria**:
- [ ] Structured result fields tested end-to-end
- [ ] Backward compatibility verified (existing tests still pass)
- [ ] Enriched handoff formatting tested with single and multiple predecessors
- [ ] Orchestrator mode tool restriction tested
- [ ] `.loomkin.toml` override tested

---

## Implementation Order

```
15.1 Structured Results ──────> 15.2 Enriched Handoffs
                                        |
                                        v
15.3 Orchestrator Mode ──────> 15.4 Testing
     (parallel track)
```

**Recommended order**:
1. **15.3** Orchestrator Mode (independent, quick win — can ship immediately)
2. **15.1** Structured Task Results (schema + tool changes)
3. **15.2** Enriched Predecessor Handoffs (the payoff — richer context flow)
4. **15.4** Testing (throughout, final coverage pass here)

## Risks & Open Questions

1. **Orchestrator mode escape hatch.** A Lead in orchestrator mode that needs to make a quick fix is stuck delegating. The `.loomkin.toml` override helps, but consider: should there be a `request_tactical_mode` tool that temporarily grants full tools with user approval?

2. **Structured field adoption.** Agents need prompt guidance to populate structured fields at completion time. The `peer_complete_task` tool params help, but Leads should also encourage specialists to report structured results.

3. **Interaction with speculative execution.** When a speculative task completes with structured fields and the assumption is later violated, the structured data should be discarded alongside the task via `discarded_tentative` status cascade.

## References

- [Random Labs — Slate: Moving Beyond ReAct and RLM](https://randomlabs.ai/blog/slate) — Original inspiration; we adopted orchestrator mode but rejected episode injection in favor of our pull-based context architecture
- [Hong, Troynikov & Huber — Context Rot](https://research.trychroma.com/context-rot) — Non-uniform attention degradation across context window (validates our decision to avoid push-based context injection)
