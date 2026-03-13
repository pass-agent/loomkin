# Epic 15: Thread Weaving — Episode-Based Context Architecture

## Problem Statement

Loomkin agents communicate via PubSub message passing and store task results as plain strings (`task.result`). When Agent B depends on Agent A's work, it receives either a flat string result or must manually query context keepers with keyword/semantic search. This creates three compounding problems:

1. **Lossy handoffs**: Task results are unstructured strings. The consuming agent has no structured understanding of what was done, what was learned, or what changed — only the final output.
2. **No composable context**: An agent starting dependent work can't inherit a predecessor's compressed work history. It either gets too little context (just the result) or too much (the full keeper transcript via retrieval).
3. **Orchestrators get pulled into tactics**: Lead agents have the full tool set (`@all_tools` — file operations, shell, git, LSP). Nothing architecturally prevents a Lead from writing code instead of delegating, which defeats the purpose of team decomposition.

Random Labs' [Slate architecture](https://randomlabs.ai/blog/slate) solves analogous problems with a primitive they call **Thread Weaving**: bounded worker threads that return compressed **episodes** to an orchestrator, where episodes are composable across threads. This epic adapts that insight to Loomkin's OTP-native multi-agent architecture.

## Core Concepts

### Episodes

An **episode** is a structured, compressed representation of an agent's work on a bounded task. Unlike a plain result string, an episode captures:
- What the agent did (actions taken)
- What it learned (discoveries, decisions)
- What changed (files modified, state mutations)
- What remains (open questions, unresolved issues)

Episodes are generated via LLM compression when an agent completes (or partially completes) a task. They replace the current `task.result` string as the primary output artifact.

### Composable Context

Episodes from predecessor tasks can be **injected** into a dependent agent's context window as a first-class enrichment layer — alongside the existing system prompt, decision context, and repo map layers. This eliminates the need for agents to manually query context keepers to understand prior work.

### Orchestrator Mode

When a Lead agent is managing a team with specialists, it operates in a **restricted tool mode** — dispatching, coordinating, and strategizing without access to tactical tools (file edit, shell, git). This enforces the strategy/tactics separation that Slate achieves through its orchestrator/thread split.

## Architecture

```
Lead Agent (orchestrator mode)
  |
  +-- dispatches task with context →  Specialist Agent
  |                                     |
  |                                     +-- executes bounded work
  |                                     +-- generates Episode on completion
  |                                     |
  +-- receives Episode ←────────────────+
  |
  +-- composes episodes → next dispatch
  |
  +-- dependent Specialist Agent ←── predecessor Episode injected into context
```

### How This Differs from Slate

| Aspect | Slate | Loomkin (this epic) |
|---|---|---|
| Threads | Ephemeral, one action, pause/resume | Persistent agents, bounded tasks |
| Episodes | Thread-scoped, returned to orchestrator | Task-scoped, stored in DB, composable |
| Orchestrator | Single central thread | Lead agent in orchestrator mode |
| Decomposition | Implicit (orchestrator dispatches) | Explicit tasks with dependency graph |
| Parallelism | Thread-level | Agent-level (already exists) |
| Persistence | In-memory episodes | PostgreSQL-backed episodes |
| Speculation | None | Existing speculative execution (6.5) |

Loomkin's advantage is that episodes integrate with the existing task dependency graph, speculative execution, and partial results systems — making them strictly more powerful than Slate's flat episode model.

## Dependencies

**No new deps required.** This builds entirely on existing infrastructure:
- Ecto schemas (task system)
- Context window enrichment layers (`context_window.ex`)
- Context offload compression patterns (`context_offload.ex`)
- Role tool configuration (`role.ex`)
- Signal bus (episode lifecycle events)

---

## 15.1: Episode Schema & Generation

**Complexity**: Large
**Dependencies**: None
**Description**: Define the episode data structure, Ecto schema for persistence, and LLM-based generation from an agent's message history at task completion boundaries.

**Files to create**:
- `lib/loomkin/episodes/episode.ex` — Episode struct and generation logic
- `lib/loomkin/schemas/episode.ex` — Ecto schema for PostgreSQL persistence

**Episode schema**:
```elixir
defmodule Loomkin.Schemas.Episode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "episodes" do
    field :team_id, :string
    field :task_id, :binary_id
    field :agent_name, :string
    field :model_used, :string

    # Structured content
    field :summary, :string           # 2-3 sentence overview
    field :actions_taken, {:array, :string}    # what was done
    field :discoveries, {:array, :string}      # what was learned
    field :files_changed, {:array, :string}    # paths modified
    field :decisions_made, {:array, :string}   # choices and rationale
    field :open_questions, {:array, :string}   # unresolved issues
    field :key_context, :string        # critical context for successors

    # Metadata
    field :token_count, :integer       # compressed episode size
    field :source_tokens, :integer     # original message history size
    field :compression_ratio, :float   # source_tokens / token_count
    field :iteration_count, :integer   # how many loop iterations

    timestamps(type: :utc_datetime)
  end
end
```

**Generation logic** (`Loomkin.Episodes.Episode`):
```elixir
def generate(agent_state, task) do
  # 1. Collect the agent's message history for this task
  # 2. Single LLM call with structured extraction prompt
  # 3. Parse response into episode fields
  # 4. Persist to PostgreSQL
  # 5. Attach episode_id to the task record
end
```

**Generation prompt template**:
```
You are compressing an agent's work session into a structured episode.
The agent was working on: {task.title}
Task description: {task.description}

Analyze the conversation history and extract:
1. SUMMARY: 2-3 sentence overview of what happened
2. ACTIONS_TAKEN: List of concrete actions (file edits, commands run, etc.)
3. DISCOVERIES: Things learned that weren't known before starting
4. FILES_CHANGED: File paths that were created or modified
5. DECISIONS_MADE: Choices made and why (brief rationale)
6. OPEN_QUESTIONS: Anything unresolved or uncertain
7. KEY_CONTEXT: Critical context a successor agent would need to continue this work

Respond in JSON format with these exact keys.
```

**Integration point**: Hook into `agent.ex` task completion flow. When an agent marks a task as `:completed` or `:partially_complete`, generate an episode from the current message history before clearing/archiving messages.

**Migration**:
```elixir
create table(:episodes, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :team_id, :string, null: false
  add :task_id, references(:team_tasks, type: :binary_id, on_delete: :nilify_all)
  add :agent_name, :string, null: false
  add :model_used, :string
  add :summary, :text, null: false
  add :actions_taken, {:array, :text}, default: []
  add :discoveries, {:array, :text}, default: []
  add :files_changed, {:array, :text}, default: []
  add :decisions_made, {:array, :text}, default: []
  add :open_questions, {:array, :text}, default: []
  add :key_context, :text
  add :token_count, :integer
  add :source_tokens, :integer
  add :compression_ratio, :float
  add :iteration_count, :integer
  timestamps(type: :utc_datetime)
end

create index(:episodes, [:team_id])
create index(:episodes, [:task_id])

# Add episode_id to team_tasks
alter table(:team_tasks) do
  add :episode_id, references(:episodes, type: :binary_id, on_delete: :nilify_all)
end
```

**Acceptance Criteria**:
- [ ] Episode schema created with all structured fields
- [ ] `generate/2` produces episode from agent message history via single LLM call
- [ ] Episode persisted to PostgreSQL on task completion
- [ ] Episode attached to task record via `episode_id` foreign key
- [ ] Compression ratio tracked (episode tokens vs source tokens)
- [ ] Generation failures are non-fatal — task still completes, episode is `nil`
- [ ] Works with both `:completed` and `:partially_complete` task statuses

---

## 15.2: Episode-Aware Task Results

**Complexity**: Medium
**Dependencies**: 15.1
**Description**: Replace the current flat `task.result` string with episode-backed results. Existing code that reads `task.result` continues to work (the summary field fills that role), but consumers can now access the full structured episode.

**Files to modify**:
- `lib/loomkin/teams/tasks.ex` — Update completion functions to generate episodes
- `lib/loomkin/teams/agent.ex` — Wire episode generation into task completion flow
- `lib/loomkin/tools/peer_complete_task.ex` — Include episode generation in tool execution

**Key changes**:

1. **`Tasks.mark_complete/3`** — After setting status to `:completed`, call `Episode.generate/2` and attach the resulting episode to the task. Set `task.result` to the episode summary for backward compatibility.

2. **`Tasks.mark_partially_complete/2`** — Generate a partial episode. Partial episodes have the same structure but may have more `open_questions` and fewer `decisions_made`. The `key_context` field is especially important here — it tells the next agent what to pick up.

3. **`Tasks.get_predecessor_outputs/1`** — Currently returns `task.result` strings. Update to return episodes (with fallback to `task.result` when no episode exists, for backward compatibility with pre-episode tasks).

**Signals**:
- `episode.generated` — team_id, task_id, episode_id, compression_ratio
- `episode.generation_failed` — team_id, task_id, reason

**Acceptance Criteria**:
- [ ] Task completion auto-generates episode
- [ ] `task.result` still populated (episode summary) for backward compatibility
- [ ] `get_predecessor_outputs/1` returns episodes when available
- [ ] Partial completion generates partial episodes
- [ ] Existing tests pass without modification (backward compat)
- [ ] Episode generation signal emitted for observability

---

## 15.3: Composable Context Injection

**Complexity**: Large
**Dependencies**: 15.1, 15.2
**Description**: Add an "episode context" enrichment layer to the context window. When an agent starts work on a task with `:requires_output` dependencies, predecessor episodes are automatically injected into the agent's system prompt — giving it structured understanding of prior work without manual context retrieval.

**Files to modify**:
- `lib/loomkin/session/context_window.ex` — Add episode injection layer
- `lib/loomkin/teams/agent.ex` — Pass task dependency info to context window builder

**New zone in context budget**:
```elixir
@zone_defaults %{
  system_prompt: 2048,
  decision_context: 1024,
  episode_context: 4096,    # NEW — predecessor episodes
  repo_map: 2048,
  tool_definitions: 2048,
  reserved_output: 4096
}
```

**Episode injection logic** (`context_window.ex`):
```elixir
def inject_episode_context(system_parts, task, opts \\ []) do
  max_tokens = Keyword.get(opts, :max_episode_tokens, 4096)

  predecessor_episodes = Episodes.Episode.for_task_predecessors(task.id)

  case predecessor_episodes do
    [] ->
      system_parts

    episodes ->
      formatted = format_episodes(episodes, max_tokens)
      system_parts ++ [formatted]
  end
end
```

**Episode formatting** (injected into system prompt):
```
## Prior Work Context

The following episodes summarize work completed by other agents that your current task depends on.

### Episode: {task_title} (by {agent_name})
**Summary**: {summary}
**Key Context**: {key_context}
**Decisions Made**: {decisions_made as bullet list}
**Open Questions**: {open_questions as bullet list}
**Files Changed**: {files_changed as bullet list}
```

**Token budgeting**: If multiple predecessor episodes exceed the 4096 token budget, prioritize by:
1. Direct dependencies (`:requires_output`) first
2. Most recent episodes first
3. Truncate `actions_taken` before truncating `key_context` or `decisions_made`

**Composability**: When Agent C depends on both Agent A and Agent B's work, both episodes are injected. The agent sees a unified view of all predecessor work — this is the "composable context" that Slate achieves through thread-to-thread episode passing.

**Acceptance Criteria**:
- [ ] Episode context layer added to context window budget allocation
- [ ] Predecessor episodes auto-injected into dependent agent's system prompt
- [ ] Token budgeting respects the 4096 default cap
- [ ] Multiple predecessor episodes compose correctly
- [ ] Priority ordering: direct deps first, recent first
- [ ] Graceful degradation: missing episodes → no injection (not an error)
- [ ] Agent doesn't need to manually call `context_retrieve` for predecessor work

---

## 15.4: Orchestrator Mode for Lead Agents

**Complexity**: Medium
**Dependencies**: None (can be implemented in parallel with 15.1-15.3)
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

## 15.5: Episode Signals & Observability

**Complexity**: Small
**Dependencies**: 15.1, 15.2
**Description**: Wire episode lifecycle events into the signal bus and workspace UI so users can see episode generation, compression ratios, and context flow between agents.

**Files to modify**:
- `lib/loomkin/signals/` — New episode signal types
- `lib/loomkin_web/live/workspace_live.ex` — Handle episode signals
- `lib/loomkin_web/live/agent_comms_component.ex` — Render episode events in comms feed

**Signal types**:
```elixir
"episode.generated"         # task_id, agent_name, compression_ratio, token_count
"episode.injected"          # target_agent, source_episodes (list), total_tokens
"episode.generation_failed" # task_id, agent_name, reason
```

**Comms feed rendering**:

| Event | Display |
|---|---|
| `episode.generated` | "{agent} compressed work into episode ({ratio}x compression, {tokens} tokens)" |
| `episode.injected` | "{agent} received context from {n} predecessor episodes ({tokens} tokens)" |
| `episode.generation_failed` | "Episode generation failed for {agent}'s task (falling back to plain result)" |

**Acceptance Criteria**:
- [ ] Episode signals emitted on generation and injection
- [ ] Comms feed renders episode events
- [ ] Compression ratio visible to users (helps tune episode quality)
- [ ] Episode injection visible (users see context flowing between agents)

---

## 15.6: Testing

**Complexity**: Medium
**Dependencies**: 15.1-15.5
**Description**: Test suite for the thread weaving system.

**Files to create**:
- `test/loomkin/episodes/episode_test.exs`
- `test/loomkin/episodes/context_injection_test.exs`
- `test/loomkin/teams/orchestrator_mode_test.exs`

**Testing strategy**:

- **Episode generation**: Mock LLM response. Verify structured fields are extracted correctly. Verify persistence to PostgreSQL. Verify attachment to task record. Test with both complete and partial task statuses.
- **Backward compatibility**: Verify existing task completion flow still works. Verify `get_predecessor_outputs/1` returns episode when available, falls back to `task.result` when not. Run existing task tests unchanged.
- **Context injection**: Create tasks with `:requires_output` dependencies. Complete predecessor tasks (generating episodes). Start dependent agent and verify episodes appear in system prompt. Test token budgeting with multiple large episodes. Test priority ordering.
- **Orchestrator mode**: Verify Lead with specialists gets restricted tool set. Verify solo Lead gets full tool set. Verify dynamic tool update when specialists join/leave. Verify `.loomkin.toml` override works.
- **Episode composability**: Chain A → B → C where each depends on the previous. Verify C's context includes both A and B episodes. Verify token budget handles composition gracefully.
- **Failure resilience**: Verify episode generation failure doesn't block task completion. Verify missing episodes don't crash context injection.

**Acceptance Criteria**:
- [ ] Episode generation tested with mocked LLM
- [ ] Backward compatibility verified (existing tests still pass)
- [ ] Context injection tested with single and multiple predecessors
- [ ] Token budgeting tested with oversized episodes
- [ ] Orchestrator mode tool restriction tested
- [ ] Failure paths tested (generation failure, missing episodes)
- [ ] Integration test: full task chain with episode flow

---

## Implementation Order

```
15.1 Episode Schema ──────> 15.2 Task Integration ──────> 15.3 Context Injection
                                      |                           |
                                      v                           v
                                15.5 Signals & UI          15.6 Testing
                                                                  ^
15.4 Orchestrator Mode ───────────────────────────────────────────┘
     (parallel track)
```

**Recommended order**:
1. **15.4** Orchestrator Mode (independent, quick win — can ship immediately)
2. **15.1** Episode Schema & Generation (foundation)
3. **15.2** Episode-Aware Task Results (wires episodes into existing flow)
4. **15.3** Composable Context Injection (the payoff — automatic context flow)
5. **15.5** Signals & Observability (makes it visible)
6. **15.6** Testing (throughout, final coverage pass here)

**Phase gate**: After 15.2, episodes exist and are attached to tasks. After 15.3, dependent agents automatically receive predecessor context. These two together are the core deliverable.

## Risks & Open Questions

1. **Episode quality vs cost.** Each episode generation is one LLM call. For teams running many small tasks, this could add meaningful cost. Consider: should episode generation be opt-in per task priority? Skip episodes for trivial tasks (single-iteration completions)?

2. **Episode staleness.** A partial episode becomes stale as the task continues. Should partial episodes be regenerated when significant new work occurs? Or is the "latest partial episode" sufficient?

3. **Orchestrator mode escape hatch.** A Lead in orchestrator mode that needs to make a quick fix is stuck delegating. The `.loomkin.toml` override helps, but consider: should there be a `request_tactical_mode` tool that temporarily grants full tools with user approval?

4. **Episode token budget.** The 4096 default for episode context may be too small for complex multi-predecessor chains or too large for simple single-dependency tasks. Consider making this proportional to the number of predecessors.

5. **Interaction with speculative execution.** When a speculative task generates an episode based on assumed inputs, and the assumption is later violated, the episode should be invalidated alongside the task. The `discarded_tentative` status should cascade to the episode.

6. **Interaction with context keepers.** Episodes and context keepers serve overlapping purposes. Long-term, episodes may replace the need for manual `context_retrieve` in most cases. Consider deprecation path.

## References

- [Random Labs — Slate: Moving Beyond ReAct and RLM](https://randomlabs.ai/blog/slate) — Thread Weaving architecture, episodes, orchestrator/thread split
- [Karpathy — LLM OS framing](https://x.com/karpathy) — Context window as RAM, processes as tool calls
- [Hong, Troynikov & Huber — Context Rot](https://research.trychroma.com/context-rot) — Non-uniform attention degradation across context window
